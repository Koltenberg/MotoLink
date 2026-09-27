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
from pathlib import Path


SCREENSHOT_NAMES = ("simulator-home.png", "simulator-large-text.png",
                    "simulator-companion.png", "simulator-companion-large-text.png",
                    "simulator-garage-light.png", "simulator-ride.png",
                    "simulator-ride-light.png", "simulator-ride-landscape.png")
ORIENTATION_EVIDENCE = "MotoLinkVisualOrientation.json"


class CaptureError(RuntimeError):
    pass


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
    evidence = temporary / ORIENTATION_EVIDENCE
    if evidence.is_file():
        shutil.copyfile(evidence, debug / ORIENTATION_EVIDENCE)
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
        raise CaptureError(f"Landscape rotation was not applied: UIKit geometry {evidence}")
    captured_at = evidence.get("capturedAt")
    if not finite_number(captured_at) or captured_at < launched_at or captured_at > time.time() + 5:
        raise CaptureError("Landscape geometry evidence does not belong to this launch")
    print(f"Landscape UIKit geometry verified: window {dimensions[0]}x{dimensions[1]}, "
          f"scene {dimensions[2]}x{dimensions[3]}", flush=True)


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
        run("install", device, app, timeout=60, deadline=deadline)
        launched = run("launch", device, bundle_id, timeout=45, deadline=deadline)
        if not re.search(r":\s*[1-9][0-9]*\s*$", launched):
            raise CaptureError(f"App launch did not return a process ID: {launched}")
        print(f"App launched: {launched}", flush=True)
        time.sleep(5)
        home = output / "simulator-home.png"
        large = output / "simulator-large-text.png"
        run("io", device, "screenshot", home, timeout=30, deadline=deadline)
        validate_png(home)
        # This UI command tests an actual requirement, unlike appearance: the
        # live app must render with large accessibility text before capture.
        run("ui", device, "content_size", "accessibility-large", timeout=30, deadline=deadline)
        time.sleep(2)
        run("io", device, "screenshot", large, timeout=30, deadline=deadline)
        validate_png(large)
        # Launch arguments only take effect in a new process. Reset Dynamic Type
        # so the companion's first image really checks the ordinary text size.
        run("terminate", device, bundle_id, timeout=30, deadline=deadline)
        run("ui", device, "content_size", "large", timeout=30, deadline=deadline)
        launched = run("launch", device, bundle_id, "--companion-visual-check", timeout=45, deadline=deadline)
        if not re.search(r":\s*[1-9][0-9]*\s*$", launched):
            raise CaptureError(f"Companion launch did not return a process ID: {launched}")
        print(f"Companion launched: {launched}", flush=True)
        time.sleep(5)
        companion = output / "simulator-companion.png"
        companion_large = output / "simulator-companion-large-text.png"
        run("io", device, "screenshot", companion, timeout=30, deadline=deadline)
        validate_png(companion)
        run("ui", device, "content_size", "accessibility-large", timeout=30, deadline=deadline)
        time.sleep(2)
        run("io", device, "screenshot", companion_large, timeout=30, deadline=deadline)
        validate_png(companion_large)
        images = [home, large, companion, companion_large]
        # Relaunch each product state in the same disposable simulator. Fixture
        # switches exist only in simulator builds; no hardware BLE is involved.
        # Keep landscape last so a previous rotation cannot taint portrait QA.
        variants = (
            ("simulator-garage-light.png", ("--review-light",), False),
            ("simulator-ride.png", ("--review-ride",), False),
            ("simulator-ride-light.png", ("--review-ride", "--review-light"), False),
            ("simulator-ride-landscape.png", ("--review-ride", "--review-landscape"), True),
        )
        for name, flags, landscape in variants:
            run("terminate", device, bundle_id, timeout=30, deadline=deadline)
            run("ui", device, "content_size", "large", timeout=30, deadline=deadline)
            if landscape:
                container = Path(run("get_app_container", device, bundle_id, "data", timeout=30, deadline=deadline))
                if not container.is_absolute() or not container.is_dir():
                    raise CaptureError("simctl did not return an existing absolute app data container")
                orientation_source = container / "Documents" / ORIENTATION_EVIDENCE
                # The prior process is terminated. Delete only our fixture file,
                # so stale geometry cannot validate the next app launch.
                orientation_source.unlink(missing_ok=True)
            launched_at = time.time()
            launched = run("launch", device, bundle_id, *flags, timeout=45, deadline=deadline)
            if not re.search(r":\s*[1-9][0-9]*\s*$", launched):
                raise CaptureError(f"{name} launch did not return a process ID: {launched}")
            print(f"Visual state launched: {name}: {launched}", flush=True)
            time.sleep(5)
            image = output / name
            run("io", device, "screenshot", image, timeout=30, deadline=deadline)
            width, height = validate_png(image)
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
            images.append(image)
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
    for name in SCREENSHOT_NAMES:
        (output / name).unlink(missing_ok=True)
    (output / ORIENTATION_EVIDENCE).unlink(missing_ok=True)
    # Clear only files owned by this capture script, never a directory tree.
    # A rerun must not mistake an old failed attempt for the current evidence.
    for attempt in range(1, 3):
        debug = output / f"debug-attempt{attempt}"
        for name in (*SCREENSHOT_NAMES, ORIENTATION_EVIDENCE, "failure.json"):
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
                if time.monotonic() >= deadline:
                    break
                continue
            for image in images:
                shutil.copyfile(image, output / image.name)
            shutil.copyfile(Path(temporary) / ORIENTATION_EVIDENCE, output / ORIENTATION_EVIDENCE)
            print(f"Simulator capture passed on attempt {attempt}: home, companion and ride states launched; all eight PNGs validated", flush=True)
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
