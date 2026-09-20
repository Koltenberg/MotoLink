#!/usr/bin/env python3
"""Validate an unsigned MotoLink device IPA without Apple SDKs or dependencies.

Checks packaging, plist, arm64 executable and Mach-O iOS platform. This cannot
prove runtime correctness, BLE compatibility, or successful personal signing.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path, PurePosixPath
import struct
import sys
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def ios_arm64_executable(data):
    # Xcode's physical iOS build is a thin arm64 MH_EXECUTE, not an arm64
    # simulator binary. Reject unknown/fat formats rather than guessing.
    require(len(data) >= 32, "Executable is shorter than a Mach-O header")
    header = struct.unpack_from("<8I", data)
    magic, cpu, _, filetype, count, commands_size, _, _ = header
    require(magic == 0xFEEDFACF, "Expected a little-endian 64-bit Mach-O executable")
    require(cpu == 0x0100000C, "Expected arm64 physical-device executable")
    require(filetype == 2, "Mach-O file is not an executable")
    require(commands_size <= len(data) - 32, "Truncated Mach-O load commands")
    offset, end, platforms = 32, 32 + commands_size, []
    for _ in range(count):
        require(offset + 8 <= end, "Truncated Mach-O command")
        command, size = struct.unpack_from("<2I", data, offset)
        require(size >= 8 and offset + size <= end, "Invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated LC_BUILD_VERSION")
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        offset += size
    require(offset == end, "Mach-O load command length does not match its header")
    require(platforms and all(x == 2 for x in platforms),
            "Expected LC_BUILD_VERSION platform iOS (2); simulator/macOS binaries cannot be installed")
    return {"architecture": "arm64", "machOPlatform": "iOS", "signedForDevice": False}


def validate(path):
    require(path.is_file(), "IPA file does not exist")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Archive has duplicate filenames")
        for name in names:
            p = PurePosixPath(name)
            require(not p.is_absolute() and ".." not in p.parts and "\\" not in name,
                    "Archive contains a nonportable or unsafe path")
        bad = archive.testzip()
        require(bad is None, "Archive CRC check failed: " + str(bad))
        roots = {PurePosixPath(n).parts[1] for n in names
                 if len(PurePosixPath(n).parts) >= 2
                 and PurePosixPath(n).parts[0] == "Payload"
                 and PurePosixPath(n).parts[1].endswith(".app")}
        require(len(roots) == 1, "Expected exactly one Payload/*.app")
        root = "Payload/" + roots.pop() + "/"
        require(root + "Info.plist" in names, "App Info.plist is missing")
        info = plistlib.loads(archive.read(root + "Info.plist"))
        require(isinstance(info, dict), "App Info.plist is not a dictionary")
        executable = info.get("CFBundleExecutable")
        require(isinstance(executable, str) and executable and "/" not in executable and "\\" not in executable
                and executable not in (".", ".."), "Invalid CFBundleExecutable")
        require(root + executable in names, "CFBundleExecutable file is missing")
        require(info.get("CFBundlePackageType") == "APPL", "Bundle is not an iOS application")
        require(isinstance(info.get("CFBundleIdentifier"), str) and bool(info["CFBundleIdentifier"]),
                "CFBundleIdentifier is missing")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
                "CFBundleSupportedPlatforms must identify physical iPhoneOS")
        require(isinstance(info.get("NSBluetoothAlwaysUsageDescription"), str)
                and bool(info["NSBluetoothAlwaysUsageDescription"].strip()), "Bluetooth permission text is missing")
        modes = info.get("UIBackgroundModes", [])
        require("bluetooth-central" in modes, "Background Bluetooth central mode is missing")
        require(root + "PrivacyInfo.xcprivacy" in names, "Privacy manifest was not copied into the app")
        require(isinstance(plistlib.loads(archive.read(root + "PrivacyInfo.xcprivacy")), dict),
                "Privacy manifest is not a dictionary")
        require(not any(n.endswith("embedded.mobileprovision") for n in names),
                "Unsigned build unexpectedly contains a provisioning profile")
        require(not any("/_CodeSignature/" in n for n in names),
                "Unsigned build unexpectedly contains a signing resource manifest")
        result = ios_arm64_executable(archive.read(root + executable))
        result.update({
            "format": "motolink-unsigned-ipa-validation-v1", "ipa": path.name,
            "bundleIdentifier": info["CFBundleIdentifier"], "executable": executable,
            "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
            "minimumOS": info.get("MinimumOSVersion"), "backgroundModes": modes,
            "runtimeTested": False, "bluetoothTested": False,
            "note": "Package structure validated; personal signing and physical-device tests remain required."
        })
    result["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    try:
        result = validate(args.ipa)
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print("IPA validation failed: " + str(error), file=sys.stderr)
        return 1
    output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.manifest:
        args.manifest.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
