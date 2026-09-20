"""Synthetic package checks; these do not compile or execute the iOS app."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "validate-ipa.py"
SPEC = importlib.util.spec_from_file_location("validate_ipa", MODULE_PATH)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class IPAPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "test.ipa"

    def package(self, *, plist_platform="iPhoneOS", binary_platform=2,
                cpu=0x0100000C, executable=True, privacy=True, extras=None):
        info = {
            "CFBundleExecutable": "MotoLink", "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "org.example.MotoLink", "CFBundleSupportedPlatforms": [plist_platform],
            "NSBluetoothAlwaysUsageDescription": "Connect to the selected motorcycle",
            "UIBackgroundModes": ["bluetooth-central"], "MinimumOSVersion": "16.0",
        }
        binary = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
        binary += struct.pack("<6I", 0x32, 24, binary_platform, 0x00100000, 0x001A0000, 0)
        with zipfile.ZipFile(self.path, "w") as archive:
            archive.writestr("Payload/MotoLink.app/Info.plist", plistlib.dumps(info))
            if executable:
                archive.writestr("Payload/MotoLink.app/MotoLink", binary)
            if privacy:
                archive.writestr("Payload/MotoLink.app/PrivacyInfo.xcprivacy", plistlib.dumps({"NSPrivacyTracking": False}))
            for name, data in (extras or {}).items():
                archive.writestr(name, data)

    def test_accepts_device_structure_but_marks_runtime_unverified(self):
        self.package()
        result = VALIDATOR.validate(self.path)
        self.assertEqual(result["machOPlatform"], "iOS")
        self.assertEqual(result["executable"], "MotoLink")
        self.assertFalse(result["runtimeTested"])
        self.assertFalse(result["signedForDevice"])
        self.assertEqual(len(result["sha256"]), 64)

    def test_rejects_simulator_plist(self):
        self.package(plist_platform="iPhoneSimulator")
        with self.assertRaisesRegex(ValueError, "physical iPhoneOS"):
            VALIDATOR.validate(self.path)

    def test_rejects_simulator_binary_even_with_device_plist(self):
        self.package(binary_platform=7)
        with self.assertRaisesRegex(ValueError, "platform iOS"):
            VALIDATOR.validate(self.path)

    def test_rejects_x86_executable(self):
        self.package(cpu=0x01000007)
        with self.assertRaisesRegex(ValueError, "arm64"):
            VALIDATOR.validate(self.path)

    def test_requires_plist_named_executable(self):
        self.package(executable=False)
        with self.assertRaisesRegex(ValueError, "Executable file is missing"):
            VALIDATOR.validate(self.path)

    def test_requires_packaged_privacy_manifest(self):
        self.package(privacy=False)
        with self.assertRaisesRegex(ValueError, "Privacy manifest"):
            VALIDATOR.validate(self.path)

    def test_rejects_provisioning_profile_in_unsigned_package(self):
        self.package(extras={"Payload/MotoLink.app/embedded.mobileprovision": b"profile"})
        with self.assertRaisesRegex(ValueError, "provisioning profile"):
            VALIDATOR.validate(self.path)

    def test_rejects_unsafe_zip_paths(self):
        self.package(extras={"Payload/../outside": b"unexpected"})
        with self.assertRaisesRegex(ValueError, "unsafe path"):
            VALIDATOR.validate(self.path)


if __name__ == "__main__":
    unittest.main()
