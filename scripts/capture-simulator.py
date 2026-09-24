#!/usr/bin/env python3
"""Capture real app UI on disposable CI simulators, with bounded recovery."""
import json
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


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


def run(*args, timeout=60, deadline=None):
    if deadline is not None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CaptureError("Simulator capture time budget exhausted")
        timeout = min(timeout, remaining)
    print("simctl " + " ".join(map(str, args)) + f" (timeout {timeout:.1f}s)", flush=True)
    result = subprocess.run(["xcrun", "simctl", *map(str, args)],
                            text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise CaptureError(f"simctl {args[0]} failed ({result.returncode}): "
                           f"{result.stdout[-4000:]} {result.stderr[-4000:]}")
    if result.stderr.strip():
        print(result.stderr.strip(), flush=True)
    return result.stdout.strip()


def cleanup(device):
    # These are only UUIDs returned by our own create call. Never shutdown all
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


def capture_attempt(app, output, device_type, runtime, bundle_id, attempt, deadline):
    device = None
    try:
        device = run("create", f"MotoLink visual check {attempt}", device_type,
                     runtime, timeout=30, deadline=deadline)
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
            raise CaptureError("simctl create did not return a device UUID")
        run("boot", device, timeout=30, deadline=deadline)
        run("bootstatus", device, "-b", timeout=150, deadline=deadline)
        # MotoLinkApp already requests .preferredColorScheme(.dark). Setting
        # global simulator appearance/status-bar decoration adds no app check
        # and has hung on otherwise booted GitHub runners. Exercise the app.
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
        return home, large
    finally:
        if device and re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
            cleanup(device)


def capture(app, output):
    app, output = Path(app).resolve(), Path(output).resolve()
    with (app / "Info.plist").open("rb") as info:
        app_info = plistlib.load(info)
    bundle_id = app_info["CFBundleIdentifier"]
    output.mkdir(parents=True, exist_ok=True)
    for name in ("simulator-home.png", "simulator-large-text.png"):
        (output / name).unlink(missing_ok=True)
    deadline = time.monotonic() + 480
    runtimes = json.loads(run("list", "runtimes", "-j", deadline=deadline))["runtimes"]
    types = json.loads(run("list", "devicetypes", "-j", deadline=deadline))["devicetypes"]
    device_type = next((item for item in types if item["name"] == "iPhone 16"), None)
    if not device_type:
        raise CaptureError("iPhone 16 simulator device type is unavailable")
    runtime = select_runtime(app_info, runtimes, device_type)
    failures = []
    for attempt in range(1, 3):
        print(f"Simulator capture attempt {attempt}/2", flush=True)
        # Publish neither partial captures nor images left by a failed attempt.
        with tempfile.TemporaryDirectory(prefix="motolink-visual-") as temporary:
            try:
                images = capture_attempt(app, Path(temporary), device_type["identifier"], runtime,
                                         bundle_id, attempt, deadline)
            except (CaptureError, subprocess.TimeoutExpired, OSError) as error:
                failures.append(f"attempt {attempt}: {error}")
                print(f"Capture failed: {failures[-1]}", flush=True)
                if time.monotonic() >= deadline:
                    break
                continue
            for image in images:
                shutil.copyfile(image, output / image.name)
            print(f"Simulator capture passed on attempt {attempt}: app launched; both PNGs validated", flush=True)
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
