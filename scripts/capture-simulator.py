#!/usr/bin/env python3
"""Capture real app UI on disposable CI simulators, with bounded recovery."""
import json
import math
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib
from pathlib import Path


SCREENSHOT_NAMES = ("simulator-home.png", "simulator-large-text.png",
                    "simulator-companion.png", "simulator-companion-large-text.png",
                    "simulator-garage-light.png", "simulator-garage-dark.png", "simulator-ride.png",
                    "simulator-ride-light.png", "simulator-bike-idle.png",
                    "simulator-bike-high-speed.png", "simulator-bike-stale.png",
                    "simulator-bike-partial.png", "simulator-bike-waiting.png",
                    "simulator-gps-recording.png", "simulator-focus-rpm.png",
                    "simulator-focus-rpm-light.png",
                    "simulator-focus-gps.png", "simulator-settings.png",
                    "simulator-scale-settings.png", "simulator-scale-editor.png", "simulator-diagnostics.png",
                    "simulator-service-editor.png", "simulator-fuel-editor.png", "simulator-history.png",
                    "simulator-graphs.png", "simulator-graphs-landscape.png",
                    "simulator-route.png", "simulator-route-landscape.png",
                    "simulator-focus-rpm-landscape.png", "simulator-ride-landscape.png")
ORIENTATION_EVIDENCE = "MotoLinkVisualOrientation.json"
READY_EVIDENCE = "MotoLinkVisualReady.json"
REFRESH_EVIDENCE = "MotoLinkRefreshLifecycle.json"
RIDE_AUDIT_EVIDENCE = "MotoLinkRideLifecycleAudit.json"
RIDE_AUDIT_REQUIRED = frozenset((
    "gps_unavailable_auto_capture", "rapid_finish_has_single_completed_ride",
    "same_connection_gatt_ready_respects_finish", "new_physical_connection_starts_new_ride",
    "actual_capture_export_matches_completed_journal", "finish_intent_durable_before_recovery_callback",
    "pending_finish_rejects_late_capture", "connection_during_recovery_starts_next_ride_after_save",
    "persisted_finish_intent_suppresses_capture_on_relaunch", "persisted_finish_completes_without_second_user_action",
    "completed_history_survives_fresh_recorder", "finish_suppression_survives_fresh_recorder",
    "no_archive_error_during_lifecycle_audit",
))
READY_NAMES = tuple(Path(name).with_suffix(".ready.json").name for name in SCREENSHOT_NAMES)
SIMCTL_DISPLAY_TIMEOUT = 90  # Hosted iOS 26 snapshots and app shutdown can exceed 30s.


class CaptureError(RuntimeError):
    pass


class UnsupportedOrientationError(CaptureError):
    """UIKit rejected the requested orientation; a fresh simulator cannot fix it."""


class LateLifecycleError(CaptureError):
    """The simulator has screenshots; retry the lifecycle locally, not a full boot."""


def launch_timed_out(error):
    return isinstance(error, CaptureError) and str(error).startswith("simctl launch timed out")


def version(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise CaptureError(f"Invalid {label}: {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def select_runtime(info, runtimes, device_type):
    sdk_name = info.get("DTSDKName", "")
    if not isinstance(sdk_name, str) or not sdk_name.startswith("iphonesimulator"):
        raise CaptureError(f"Simulator app must record DTSDKName=iphonesimulator<version>; got {sdk_name!r}")
    sdk = version(sdk_name.removeprefix("iphonesimulator"), "simulator SDK version")
    app_minimum = version(info.get("MinimumOSVersion"), "app MinimumOSVersion")
    device_minimum = version(device_type.get("minRuntimeVersionString", "0"), "device minimum runtime")
    minimum = max(app_minimum, device_minimum)
    print(f"Simulator selection: SDK={sdk_name}; app minimum={info.get('MinimumOSVersion')}; "
          f"device={device_type['name']}; device minimum={device_type.get('minRuntimeVersionString', 'not reported')}", flush=True)
    candidates = []
    for runtime in runtimes:
        identifier = runtime.get("identifier", "unknown")
        runtime_name = runtime.get("name", "unknown")
        if "iOS" not in runtime_name:
            reason = "not iOS"
        elif not runtime.get("isAvailable"):
            reason = "unavailable: " + str(runtime.get("availabilityError") or "not reported")
        else:
            try:
                runtime_version = version(runtime.get("version"), "runtime version")
            except CaptureError as error:
                reason = str(error)
            else:
                if runtime_version < minimum:
                    reason = "older than app/device minimum"
                elif runtime_version > sdk:
                    # This is a deterministic CI policy, not a claim that Apple
                    # universally prohibits newer runtimes with an older SDK.
                    reason = "newer than selected SDK (CI selection policy)"
                else:
                    reason = "candidate: exact SDK match" if runtime_version == sdk else "candidate: older than SDK"
                    candidates.append((runtime_version, identifier))
        print(f"Runtime {runtime_name} ({runtime.get('version', '?')}, {identifier}): {reason}", flush=True)
    if not candidates:
        raise CaptureError(f"No available iOS runtime between app/device minimum {minimum} and SDK {sdk}; "
                           "install a matching runtime for the selected Xcode")
    selected = max(candidates)[1]
    print(f"Selected simulator runtime: {selected}; SDK={sdk_name}", flush=True)
    return selected


def select_device_type(types):
    # Use an observed type from the installed Xcode. Current runner images
    # provide iPhone 17; older Xcodes retain the previous iPhone 16 baseline.
    for name in ("iPhone 17", "iPhone 16"):
        selected = next((item for item in types if item.get("name") == name), None)
        if selected is not None:
            return selected
    raise CaptureError("Neither iPhone 17 nor iPhone 16 simulator device type is available")


def select_runner_seed(devices, runtime, device_type):
    # Only a matching precreated, stopped device from the disposable hosted
    # image is a seed. Do not choose a failed clone from an earlier attempt.
    for device in devices.get(runtime, []):
        if (device.get("isAvailable") is True and device.get("state") == "Shutdown"
                and device.get("deviceTypeIdentifier") == device_type["identifier"]
                and device.get("name") == device_type["name"]
                and re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
                                 device.get("udid", ""))):
            return device["udid"]
    return None


def output_text(value):
    # TimeoutExpired output is bytes even when subprocess.run(text=True).
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")


def boot_with_progress(command, timeout):
    # Inherit stdout/stderr directly: boot stages reach CI's tee immediately,
    # without pipe buffering or a reader thread. Never wait() with PIPEs here.
    started = time.monotonic()
    process = subprocess.Popen(command)
    try:
        while True:
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            try:
                code = process.wait(timeout=min(30, remaining))
            except subprocess.TimeoutExpired:
                elapsed = time.monotonic() - started
                print(f"Simulator boot still running after {elapsed:.0f}s "
                      f"(limit {timeout:.0f}s); boot stages are streamed above", flush=True)
                continue
            if code:
                raise CaptureError(f"simctl bootstatus failed ({code}); see streamed boot stages above")
            return ""
    finally:
        if process.poll() is None:
            # This kills only the simctl client we started, not CoreSimulator
            # or any other device. Keep even process reaping bounded.
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                print("Boot client did not exit within 5s after kill", flush=True)


def run(*args, timeout=60, deadline=None):
    if deadline is not None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CaptureError("Simulator capture time budget exhausted")
        timeout = min(timeout, remaining)
    print("simctl " + " ".join(map(str, args)) + f" (timeout {timeout:.1f}s)", flush=True)
    command = ["xcrun", "simctl", *map(str, args)]
    try:
        if args[0] == "bootstatus":
            return boot_with_progress(command, timeout)
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stdout = output_text(error.stdout)[-8000:]
        stderr = output_text(error.stderr)[-8000:]
        detail = f"simctl {args[0]} timed out after {timeout:.1f}s"
        if stdout:
            detail += f"\nCaptured stdout:\n{stdout}"
        if stderr:
            detail += f"\nCaptured stderr:\n{stderr}"
        if args[0] == "bootstatus":
            detail += "; see streamed boot stages above"
        raise CaptureError(detail) from error
    if result.returncode:
        raise CaptureError(f"simctl {args[0]} failed ({result.returncode}): "
                           f"{result.stdout[-4000:]} {result.stderr[-4000:]}")
    if result.stderr.strip():
        print(result.stderr.strip(), flush=True)
    return result.stdout.strip()


def cleanup(device):
    # These are only UUIDs returned by our own create/clone call. Never shutdown all
    # devices, restart CoreSimulatorService, or touch a physical phone.
    for command in ("shutdown", "delete"):
        try:
            run(command, device, timeout=10)
        except (CaptureError, subprocess.TimeoutExpired, OSError) as error:
            # Cleanup must neither hide the original failure nor skip deletion
            # because shutdown timed out (the previous script did both).
            print(f"Cleanup warning for {device}: {command}: {error}", flush=True)


def validate_png(path):
    if not path.is_file():
        raise CaptureError(f"Screenshot was not created: {path.name}")
    with path.open("rb") as image:
        header = image.read(24)
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            raise CaptureError(f"Invalid PNG screenshot: {path.name}")
        width, height = struct.unpack(">II", header[16:24])
        if width < 300 or height < 300 or path.stat().st_size < 1000:
            raise CaptureError(f"Incomplete screenshot: {path.name}")
        image.seek(-12, 2)
        if image.read() != b"\x00\x00\x00\x00IEND\xaeB`\x82":
            raise CaptureError(f"Truncated screenshot: {path.name}")
    return width, height


def reject_blank_png(path):
    """Reject a launch-screen buffer using the central image, without Pillow."""
    data = path.read_bytes()
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", data[16:29])
    channels = {2: 3, 6: 4}.get(color)
    if depth != 8 or channels is None or compression or filtering or interlace:
        raise CaptureError(f"Unsupported screenshot pixel format: {path.name}")
    stride = width * channels
    expected = (stride + 1) * height
    if expected > 128 * 1024 * 1024:
        raise CaptureError("Screenshot dimensions exceed the visual check budget")
    compressed = bytearray()
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if offset + 12 + length > len(data):
            raise CaptureError(f"Truncated PNG chunk: {path.name}")
        if kind == b"IDAT":
            compressed.extend(data[offset + 8:offset + 8 + length])
        offset += 12 + length
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(compressed, expected + 1)
        if len(raw) != expected or not decoder.eof:
            raise CaptureError(f"Incomplete PNG pixels: {path.name}")
    except zlib.error as error:
        raise CaptureError(f"Invalid PNG pixels: {path.name}: {error}") from error
    previous = bytearray(stride)
    palette = set()
    for y in range(height):
        start = y * (stride + 1)
        method = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        if method == 1:
            for x in range(channels, stride):
                row[x] = (row[x] + row[x - channels]) & 255
        elif method == 2:
            row = bytearray((value + up) & 255 for value, up in zip(row, previous))
        elif method in (3, 4):
            for x in range(stride):
                left = row[x - channels] if x >= channels else 0
                up = previous[x]
                corner = previous[x - channels] if x >= channels else 0
                if method == 3:
                    predictor = (left + up) // 2
                else:
                    estimate = left + up - corner
                    a, b, c = abs(estimate - left), abs(estimate - up), abs(estimate - corner)
                    predictor = left if a <= b and a <= c else up if b <= c else corner
                row[x] = (row[x] + predictor) & 255
        elif method != 0:
            raise CaptureError(f"Invalid PNG filter: {path.name}")
        previous = row
        # Exclude the status bar, Dynamic Island and home indicator: those can
        # be visible while the entire app is still an empty launch snapshot.
        if height * 0.15 < y < height * 0.85 and y % max(1, height // 80) == 0:
            for x in range(width // 10, width * 9 // 10, max(1, width // 80)):
                index = x * channels
                palette.add(tuple(value // 16 for value in row[index:index + 3]))
                if len(palette) >= 6:
                    return
    raise CaptureError(f"Blank or near-uniform app screenshot: {path.name}")


def validate_capture(path):
    dimensions = validate_png(path)
    reject_blank_png(path)
    return dimensions


def preserve_failed_attempt(temporary, output, attempt, error):
    """Keep raw evidence separate from the complete, validated capture set."""
    debug = output / f"debug-attempt{attempt}"
    debug.mkdir(parents=True, exist_ok=True)
    screenshots = []
    for name in SCREENSHOT_NAMES:
        source = temporary / name
        if not source.is_file():
            continue
        shutil.copyfile(source, debug / name)
        record = {"name": name}
        try:
            record["width"], record["height"] = validate_png(source)
            record["valid_png"] = True
        except (CaptureError, OSError) as validation_error:
            record.update(valid_png=False, error=str(validation_error))
        screenshots.append(record)
    for name in (*READY_NAMES, ORIENTATION_EVIDENCE, REFRESH_EVIDENCE, RIDE_AUDIT_EVIDENCE):
        evidence = temporary / name
        if evidence.is_file():
            shutil.copyfile(evidence, debug / name)
    (debug / "failure.json").write_text(json.dumps({
        "status": "failed", "attempt": attempt, "error": str(error),
        "note": "Diagnostic captures only; this is not a passed visual validation set.",
        "screenshots": screenshots,
    }, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(screenshots)} diagnostic screenshots in {debug}", flush=True)


def validate_landscape_evidence(path, launched_at):
    """Validate UIKit geometry, not the headless simulator's display pixels."""
    try:
        if path.stat().st_size > 65536:
            raise CaptureError("Landscape geometry evidence is unexpectedly large")
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CaptureError(f"Missing or invalid landscape geometry evidence: {error}") from error
    if not isinstance(evidence, dict):
        raise CaptureError("Landscape geometry evidence must be an object")

    def finite_number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

    dimensions = [evidence.get(key) for key in ("windowWidth", "windowHeight", "sceneWidth", "sceneHeight")]
    if (evidence.get("interfaceLandscape") is not True
            or evidence.get("interfaceOrientation") not in (3, 4)
            or evidence.get("error", "missing") is not None
            or not all(finite_number(value) for value in dimensions)
            or not dimensions[0] > dimensions[1] > 0
            or not dimensions[2] > dimensions[3] > 0):
        raise UnsupportedOrientationError(f"Landscape rotation was not applied: UIKit geometry {evidence}")
    captured_at = evidence.get("capturedAt")
    if not finite_number(captured_at) or captured_at < launched_at or captured_at > time.time() + 5:
        raise CaptureError("Landscape geometry evidence does not belong to this launch")
    print(f"Landscape UIKit geometry verified: window {dimensions[0]}x{dimensions[1]}, "
          f"scene {dimensions[2]}x{dimensions[3]}", flush=True)


def wait_for_orientation_evidence(path, deadline):
    # The process ID can arrive before SwiftUI appears. Wait only for the
    # atomic fixture file; invalid contents are never polled until they pass.
    until = min(deadline, time.monotonic() + 10)
    for poll in range(21):
        remaining = until - time.monotonic()
        if remaining <= 0:
            break
        if path.is_file():
            return
        if poll < 20:
            time.sleep(min(0.5, remaining))
    raise CaptureError("Missing landscape geometry evidence after bounded wait (up to 10s)")


def launch_for_capture(device, bundle_id, flags, container, output, name, deadline):
    source = container / "Documents" / READY_EVIDENCE
    source.unlink(missing_ok=True)
    if "--review-ride" in flags:
        (container / "Documents" / REFRESH_EVIDENCE).unlink(missing_ok=True)
    token = str(uuid.uuid4())
    started = time.time()
    try:
        launched = run("launch", device, bundle_id, *flags, "--visual-review-token", token,
                       timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
    except CaptureError as error:
        if not launch_timed_out(error):
            raise
        # CoreSimulator can time out the command after launching the app.
        # Only this launch's fresh tokenized UIKit readiness can recover it.
        print(f"Launch command timed out for {name}; checking visible app readiness", flush=True)
        launched = None
    if launched is not None and not re.search(r":\s*[1-9][0-9]*\s*$", launched):
        raise CaptureError(f"App launch did not return a process ID: {launched}")
    graphs = "--review-graphs" in flags or "--review-graphs-fullscreen" in flags
    route = "--review-route-fullscreen" in flags
    mode = "ride" if "--review-ride" in flags else "route" if route else "graphs" if graphs else "companion" if "--companion-visual-check" in flags else "garage"
    theme = "light" if "--review-light" in flags else "dark" if "--review-dark" in flags or "--review-ride" in flags or graphs or route else None
    until = min(deadline, time.monotonic() + 20)
    for poll in range(41):
        remaining = until - time.monotonic()
        if remaining <= 0:
            break
        if source.is_file():
            destination = output / Path(name).with_suffix(".ready.json").name
            shutil.copyfile(source, destination)
            validate_visual_ready(destination, token, mode, theme, started)
            print(f"Visible app ready: {name}: {launched or 'confirmed after command timeout'}", flush=True)
            return started
        if poll < 40:
            time.sleep(min(0.5, remaining))
    raise CaptureError(f"Visible app readiness was not confirmed within 20s: {name}")


def validate_visual_ready(path, token, mode, theme, launched_at):
    try:
        if path.stat().st_size > 65536:
            raise CaptureError("Visual readiness evidence is unexpectedly large")
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CaptureError(f"Invalid visual readiness evidence: {error}") from error
    if not isinstance(evidence, dict):
        raise CaptureError("Visual readiness evidence must be an object")
    values = [evidence.get(key) for key in ("windowWidth", "windowHeight", "capturedAt", "visibleSeconds")]
    if (evidence.get("ready") is not True or evidence.get("launchToken") != token
            or evidence.get("mode") != mode or evidence.get("appearance") not in ("dark", "light")
            or (theme is not None and evidence.get("appearance") != theme)
            or not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                       and math.isfinite(value) for value in values)
            or min(values[:2]) <= 0 or values[3] < 2
            or not launched_at <= values[2] <= time.time() + 5):
        raise CaptureError(f"Visual readiness does not match this visible app launch: {evidence}")


def read_refresh_evidence(path, token, launched_at, identity=None):
    """Only genuine timer callbacks from this process may prove a resume."""
    try:
        if path.stat().st_size > 131072:
            raise CaptureError("Refresh lifecycle evidence is unexpectedly large")
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CaptureError(f"Invalid refresh lifecycle evidence: {error}") from error
    def finite(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    if (not isinstance(evidence, dict) or evidence.get("launchToken") != token
            or not isinstance(evidence.get("instanceToken"), str) or not evidence["instanceToken"]
            or type(evidence.get("processID")) is not int or evidence["processID"] <= 0
            or not finite(evidence.get("capturedAt"))
            or not launched_at <= evidence["capturedAt"] <= time.time() + 5
            or not isinstance(evidence.get("events"), list) or not evidence["events"]):
        raise CaptureError("Refresh evidence does not belong to this app launch")
    if identity is not None and identity != (evidence["processID"], evidence["instanceToken"]):
        raise CaptureError("App restarted during lifecycle check; this cannot prove timer resumption")
    previous_sequence, previous_uptime = 0, -1
    for event in evidence["events"]:
        if (not isinstance(event, dict) or type(event.get("sequence")) is not int
                or event["sequence"] <= previous_sequence
                or event.get("kind") not in ("timer", "sample", "background", "active")
                or type(event.get("appState")) is not int or event["appState"] not in (0, 1, 2)
                or not finite(event.get("at")) or not launched_at <= event["at"] <= evidence["capturedAt"]
                or not finite(event.get("uptime")) or event["uptime"] < previous_uptime
                or (event["kind"] in ("timer", "sample") and event.get("panel") not in ("telemetry", "speed"))):
            raise CaptureError("Invalid or stale refresh lifecycle event")
        previous_sequence, previous_uptime = event["sequence"], event["uptime"]
    return evidence


def panels_are_ticking(evidence, after_sequence=0):
    for panel in ("telemetry", "speed"):
        ticks = [event for event in evidence["events"] if event["sequence"] > after_sequence
                 and event["kind"] == "timer" and event.get("panel") == panel and event["appState"] == 0]
        if len(ticks) < 2 or ticks[-1]["uptime"] - ticks[0]["uptime"] < 0.5:
            return False
    return True


def resumed_panels_are_ticking(evidence, background_sequence):
    active = next((event for event in evidence["events"] if event["sequence"] > background_sequence
                   and event["kind"] == "active" and event["appState"] == 0), None)
    return active is not None and panels_are_ticking(evidence, active["sequence"])


def wait_for_refresh(path, token, launched_at, predicate, description, deadline, identity=None):
    until = min(deadline, time.monotonic() + 12)
    for poll in range(25):
        remaining = until - time.monotonic()
        if remaining <= 0:
            break
        if path.is_file():
            evidence = read_refresh_evidence(path, token, launched_at, identity)
            if predicate(evidence):
                return evidence
        if poll < 24:
            time.sleep(min(0.5, remaining))
    raise CaptureError("Refresh lifecycle check failed: " + description + " within 12s")


def verify_refresh_lifecycle(device, bundle_id, container, output, launched_at, deadline):
    source = container / "Documents" / REFRESH_EVIDENCE
    ready = json.loads((output / "simulator-ride.ready.json").read_text(encoding="utf-8"))
    token = ready["launchToken"]
    try:
        initial = wait_for_refresh(source, token, launched_at, panels_are_ticking,
                                   "both real panel timers must tick before background", deadline)
        identity = (initial["processID"], initial["instanceToken"])
        baseline_sequence = initial["events"][-1]["sequence"]
        # Open a real second app. Do not terminate MotoLink: a fresh onAppear in
        # a new process would hide the exact foreground timer regression.
        for preference_attempt in (1, 2):
            try:
                run("launch", device, "com.apple.Preferences",
                    timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
            except CaptureError as error:
                if not launch_timed_out(error):
                    raise
                print("Settings launch command timed out; checking UIKit background evidence", flush=True)
            try:
                background = wait_for_refresh(source, token, launched_at,
                    lambda value: any(event["sequence"] > baseline_sequence and event["kind"] == "background"
                                      and event["appState"] == 2 for event in value["events"]),
                    "UIKit must confirm background", deadline, identity)
                break
            except CaptureError as error:
                if preference_attempt == 2 or "within 12s" not in str(error):
                    raise
                print("Settings did not background MotoLink; retrying launch on the same simulator", flush=True)
        boundary = next(event["sequence"] for event in background["events"]
                        if event["sequence"] > baseline_sequence and event["kind"] == "background"
                        and event["appState"] == 2)
        try:
            resumed = run("launch", device, bundle_id,
                          timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        except CaptureError as error:
            if not launch_timed_out(error):
                raise
            # The same process and fresh post-foreground timers below prove a
            # real resume even if the simctl client stalls after dispatch.
            print("Foreground command timed out; checking same-process timer evidence", flush=True)
            resumed = None
        if resumed is not None:
            match = re.search(r":\s*([1-9][0-9]*)\s*$", resumed)
            if match is None or int(match.group(1)) != identity[0]:
                raise CaptureError("Foreground launch did not preserve the original MotoLink process")
        final = wait_for_refresh(source, token, launched_at,
            lambda value: resumed_panels_are_ticking(value, boundary),
            "both real panel timers must tick twice after foreground", deadline, identity)
        print("Foreground regression passed: same process, confirmed background/active, "
              "two fresh timer samples per dashboard panel", flush=True)
        return final
    finally:
        if source.is_file():
            shutil.copyfile(source, output / REFRESH_EVIDENCE)


def validate_ride_audit(path, token, launched_at):
    try:
        if path.stat().st_size > 65536:
            raise CaptureError("Ride lifecycle audit is unexpectedly large")
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CaptureError(f"Invalid ride lifecycle audit: {error}") from error
    if not isinstance(evidence, dict):
        raise CaptureError("Ride lifecycle audit must be an object")
    checks = evidence.get("checks")
    times = [evidence.get("startedAt"), evidence.get("finishedAt")]
    if (evidence.get("launchToken") != token or evidence.get("passed") is not True
            or evidence.get("failures") != []
            or evidence.get("schema") != "motolink.simulator-ride-lifecycle/1"
            or not isinstance(checks, list) or len(checks) < len(RIDE_AUDIT_REQUIRED)
            or any(not isinstance(c, dict) or c.get("passed") is not True
                   or not isinstance(c.get("name"), str) or not c["name"] for c in checks)
            or len({c["name"] for c in checks}) != len(checks)
            or not RIDE_AUDIT_REQUIRED.issubset({c["name"] for c in checks})
            or not all(isinstance(t, (int, float)) and not isinstance(t, bool)
                       and math.isfinite(t) for t in times)
            or not launched_at <= times[0] <= times[1] <= time.time() + 5):
        raise CaptureError(f"Ride lifecycle audit failed or is stale: {evidence}")
    return evidence


def verify_recorder_lifecycle(device, bundle_id, container, output, deadline):
    # This is the same disposable simulator used above, after every visual
    # fixture. Exercise the real recorder and archive with no GPS access.
    run("terminate", device, bundle_id, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
    run("privacy", device, "revoke", "location", bundle_id, timeout=30, deadline=deadline)
    source = container / "Documents" / RIDE_AUDIT_EVIDENCE
    source.unlink(missing_ok=True)
    token, started = str(uuid.uuid4()), time.time()
    try:
        run("launch", device, bundle_id, "--audit-ride-lifecycle", "--visual-review-token", token,
            timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
    except CaptureError as error:
        if not launch_timed_out(error):
            raise
    until = min(deadline, time.monotonic() + 60)
    while time.monotonic() < until:
        if source.is_file():
            destination = output / RIDE_AUDIT_EVIDENCE
            shutil.copyfile(source, destination)
            try:
                evidence = validate_ride_audit(destination, token, started)
            except CaptureError as error:
                raise LateLifecycleError(str(error)) from error
            print(f"Actual recorder/archive audit passed: {len(evidence['checks'])} checks", flush=True)
            return
        time.sleep(min(0.5, max(0, until - time.monotonic())))
    raise LateLifecycleError("Actual recorder/archive audit did not finish within 60 seconds")


def capture_attempt(app, output, device_type, runtime, bundle_id, attempt, deadline, seed=None):
    device = None
    try:
        name = f"MotoLink visual check {attempt}"
        if seed:
            print(f"Cloning hosted image device {seed}; source remains untouched", flush=True)
            created = run("clone", seed, name, timeout=60, deadline=deadline)
        else:
            created = run("create", name, device_type, runtime, timeout=30, deadline=deadline)
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", created) or created == seed:
            raise CaptureError("simctl create/clone did not return a new device UUID")
        device = created
        run("boot", device, timeout=30, deadline=deadline)
        run("bootstatus", device, "-b", timeout=300, deadline=deadline)
        # Appearance variants are app launch arguments, not global simulator
        # settings: global appearance/status-bar decoration has hung on
        # otherwise booted GitHub runners. Exercise the app's own theme.
        # A hosted iOS 26 simulator may finish booting well before its app
        # installation service is ready. Keep the install bounded by both the
        # per-call limit and the overall visual-capture deadline.
        run("install", device, app, timeout=180, deadline=deadline)
        container = Path(run("get_app_container", device, bundle_id, "data", timeout=30, deadline=deadline))
        if not container.is_absolute() or not container.is_dir():
            raise CaptureError("simctl did not return an existing absolute app data container")
        launch_for_capture(device, bundle_id, (), container, output, "simulator-home.png", deadline)
        home = output / "simulator-home.png"
        large = output / "simulator-large-text.png"
        run("io", device, "screenshot", home, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        validate_capture(home)
        # This UI command tests an actual requirement, unlike appearance: the
        # live app must render with large accessibility text before capture.
        run("ui", device, "content_size", "accessibility-large", timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        time.sleep(2)
        run("io", device, "screenshot", large, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        validate_capture(large)
        shutil.copyfile(home.with_suffix(".ready.json"), large.with_suffix(".ready.json"))
        # Launch arguments only take effect in a new process. Reset Dynamic Type
        # so the companion's first image really checks the ordinary text size.
        run("terminate", device, bundle_id, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        run("ui", device, "content_size", "large", timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        launch_for_capture(device, bundle_id, ("--companion-visual-check",), container, output,
                           "simulator-companion.png", deadline)
        companion = output / "simulator-companion.png"
        companion_large = output / "simulator-companion-large-text.png"
        run("io", device, "screenshot", companion, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        validate_capture(companion)
        run("ui", device, "content_size", "accessibility-large", timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        time.sleep(2)
        run("io", device, "screenshot", companion_large, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
        validate_capture(companion_large)
        shutil.copyfile(companion.with_suffix(".ready.json"), companion_large.with_suffix(".ready.json"))
        images = [home, large, companion, companion_large]
        # Relaunch each product state in the same disposable simulator. Fixture
        # switches exist only in simulator builds; no hardware BLE is involved.
        # Keep landscape last so a previous rotation cannot taint portrait QA.
        variants = (
            ("simulator-garage-light.png", ("--review-light",), False),
            ("simulator-garage-dark.png", ("--review-dark",), False),
            ("simulator-ride.png", ("--review-ride",), False),
            ("simulator-ride-light.png", ("--review-ride", "--review-light"), False),
            ("simulator-bike-idle.png", ("--review-ride", "--review-bike-idle"), False),
            ("simulator-bike-high-speed.png", ("--review-ride", "--review-bike-high-speed"), False),
            ("simulator-bike-stale.png", ("--review-ride", "--review-bike-stale"), False),
            ("simulator-bike-partial.png", ("--review-ride", "--review-bike-partial"), False),
            ("simulator-bike-waiting.png", ("--review-ride", "--review-bike-waiting"), False),
            ("simulator-gps-recording.png", ("--review-ride", "--review-gps-recording"), False),
            ("simulator-focus-rpm.png", ("--review-ride", "--review-focus-rpm"), False),
            ("simulator-focus-rpm-light.png",
             ("--review-ride", "--review-focus-rpm", "--review-light"), False),
            ("simulator-focus-gps.png", ("--review-ride", "--review-focus-gps", "--review-light"), False),
            ("simulator-settings.png", ("--review-settings", "--review-light"), False),
            ("simulator-scale-settings.png", ("--review-scale-settings", "--review-light"), False),
            ("simulator-scale-editor.png", ("--review-scale-editor", "--review-light"), False),
            ("simulator-diagnostics.png", ("--review-diagnostics", "--review-light"), False),
            ("simulator-service-editor.png", ("--companion-visual-check", "--review-service-editor", "--review-light"), False),
            ("simulator-fuel-editor.png", ("--companion-visual-check", "--review-fuel-editor", "--review-light"), False),
            ("simulator-history.png", ("--review-history", "--review-light"), False),
            ("simulator-graphs.png", ("--review-graphs", "--review-light"), False),
            ("simulator-route.png", ("--review-route-fullscreen", "--review-route-estimates", "--review-light"), False),
            ("simulator-graphs-landscape.png",
             ("--review-graphs-fullscreen", "--review-landscape"), True),
            ("simulator-route-landscape.png",
             ("--review-route-fullscreen", "--review-route-estimates", "--review-landscape"), True),
            ("simulator-focus-rpm-landscape.png",
             ("--review-ride", "--review-focus-rpm", "--review-landscape"), True),
            ("simulator-ride-landscape.png", ("--review-ride", "--review-landscape"), True),
        )
        for name, flags, landscape in variants:
            run("terminate", device, bundle_id, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
            run("ui", device, "content_size", "large", timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
            if landscape:
                orientation_source = container / "Documents" / ORIENTATION_EVIDENCE
                # The prior process is terminated. Delete only our fixture file,
                # so stale geometry cannot validate the next app launch.
                orientation_source.unlink(missing_ok=True)
            launched_at = launch_for_capture(device, bundle_id, flags, container, output, name, deadline)
            if landscape:
                wait_for_orientation_evidence(orientation_source, deadline)
            image = output / name
            run("io", device, "screenshot", image, timeout=SIMCTL_DISPLAY_TIMEOUT, deadline=deadline)
            width, height = validate_capture(image)
            if landscape:
                evidence = output / ORIENTATION_EVIDENCE
                try:
                    shutil.copyfile(orientation_source, evidence)
                except OSError as error:
                    raise CaptureError(f"Missing landscape geometry evidence: {error}") from error
                validate_landscape_evidence(evidence, launched_at)
                # Headless simctl can capture its physical portrait display
                # with a landscape UIKit scene rendered sideways. Preserve the
                # raw screenshot; actual scene/window geometry is checked above.
                print(f"Raw landscape screenshot retained at {width}x{height}", flush=True)
            if not landscape and width >= height:
                raise CaptureError(f"Portrait state was not restored: {name} is {width}x{height}")
            if name == "simulator-ride.png":
                try:
                    verify_refresh_lifecycle(device, bundle_id, container, output, launched_at, deadline)
                except CaptureError as error:
                    # The screenshot and timer trace survive for diagnosis;
                    # retrying Settings here is cheaper than another boot.
                    raise LateLifecycleError(str(error)) from error
            images.append(image)
        verify_recorder_lifecycle(device, bundle_id, container, output, deadline)
        return tuple(images)
    finally:
        if device and re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
            cleanup(device)


def capture(app, output):
    app, output = Path(app).resolve(), Path(output).resolve()
    with (app / "Info.plist").open("rb") as info:
        app_info = plistlib.load(info)
    bundle_id = app_info["CFBundleIdentifier"]
    output.mkdir(parents=True, exist_ok=True)
    for name in (*SCREENSHOT_NAMES, *READY_NAMES):
        (output / name).unlink(missing_ok=True)
    for name in (ORIENTATION_EVIDENCE, REFRESH_EVIDENCE, RIDE_AUDIT_EVIDENCE):
        (output / name).unlink(missing_ok=True)
    # Clear only files owned by this capture script, never a directory tree.
    # A rerun must not mistake an old failed attempt for the current evidence.
    for attempt in range(1, 3):
        debug = output / f"debug-attempt{attempt}"
        for name in (*SCREENSHOT_NAMES, *READY_NAMES, ORIENTATION_EVIDENCE, REFRESH_EVIDENCE, RIDE_AUDIT_EVIDENCE, "failure.json"):
            (debug / name).unlink(missing_ok=True)
    deadline = time.monotonic() + 900
    runtimes = json.loads(run("list", "runtimes", "-j", deadline=deadline))["runtimes"]
    types = json.loads(run("list", "devicetypes", "-j", deadline=deadline))["devicetypes"]
    device_type = select_device_type(types)
    runtime = select_runtime(app_info, runtimes, device_type)
    seed = None
    if os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted":
        devices = json.loads(run("list", "devices", "-j", deadline=deadline))["devices"]
        seed = select_runner_seed(devices, runtime, device_type)
        print("Hosted simulator seed: " + (seed or "none available; create a fresh device"), flush=True)
    failures = []
    for attempt in range(1, 3):
        print(f"Simulator capture attempt {attempt}/2", flush=True)
        # Only complete captures reach the top level; failures retain raw
        # evidence in explicitly failed diagnostic directories.
        with tempfile.TemporaryDirectory(prefix="motolink-visual-") as temporary:
            try:
                images = capture_attempt(app, Path(temporary), device_type["identifier"], runtime,
                                         bundle_id, attempt, deadline, seed=seed)
            except (CaptureError, subprocess.TimeoutExpired, OSError) as error:
                failures.append(f"attempt {attempt}: {error}")
                print(f"Capture failed: {failures[-1]}", flush=True)
                try:
                    preserve_failed_attempt(Path(temporary), output, attempt, error)
                except OSError as diagnostic_error:
                    print(f"Could not preserve diagnostic screenshots: {diagnostic_error}", flush=True)
                if isinstance(error, UnsupportedOrientationError):
                    print("UIKit rejected landscape; a second fresh simulator would repeat the app-level failure", flush=True)
                    break
                if isinstance(error, LateLifecycleError):
                    print("Lifecycle failed after an in-place retry; keeping the current diagnostic captures", flush=True)
                    break
                if time.monotonic() >= deadline:
                    break
                continue
            for image in images:
                shutil.copyfile(image, output / image.name)
                shutil.copyfile(image.with_suffix(".ready.json"), output / image.with_suffix(".ready.json").name)
            shutil.copyfile(Path(temporary) / ORIENTATION_EVIDENCE, output / ORIENTATION_EVIDENCE)
            shutil.copyfile(Path(temporary) / REFRESH_EVIDENCE, output / REFRESH_EVIDENCE)
            shutil.copyfile(Path(temporary) / RIDE_AUDIT_EVIDENCE, output / RIDE_AUDIT_EVIDENCE)
            print(f"Simulator capture passed on attempt {attempt}: home, companion and ride states launched; all {len(images)} PNGs validated", flush=True)
            return
    raise CaptureError("Simulator visual validation failed: " + "; ".join(failures))


def main(argv):
    if len(argv) != 2:
        raise CaptureError("Usage: capture-simulator.py APP_DIRECTORY OUTPUT_DIRECTORY")
    capture(*argv)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (CaptureError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
