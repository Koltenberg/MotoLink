"""Infrastructure regression checks; no simulator, Apple account or phone used."""
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("capture_simulator",
    Path(__file__).resolve().parents[1] / "scripts" / "capture-simulator.py")
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


def screenshot(path, marker=b"", dimensions=(1170, 2532)):
    # Minimal structure used by the packaging guard; UI correctness is checked
    # with real screenshots in macOS CI, not asserted by this fake PNG.
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                     + struct.pack(">II", *dimensions) + marker + b"x" * 1100
                     + b"\x00\x00\x00\x00IEND\xaeB`\x82")


class SimulatorCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "MotoLink.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.koltenberg.MotoLink",
            "DTSDKName": "iphonesimulator18.5", "MinimumOSVersion": "16.0"}))
        self.output = self.root / "output"
        self.calls = []
        self.devices = []
        self.failure = None
        self.launch_result = "org.koltenberg.MotoLink: 1234"
        self.active_mode = None
        self.content_size = "large"
        self.theme = "default"
        self.landscape = False

    def fake_run(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ("list", "runtimes"):
            return json.dumps({"runtimes": [{"identifier": "runtime-ios", "isAvailable": True,
                                            "name": "iOS 18.5", "version": "18.5"}]})
        if args[:2] == ("list", "devicetypes"):
            return json.dumps({"devicetypes": [{"name": "iPhone 16", "identifier": "iphone16"}]})
        if args[0] == "create":
            device = f"00000000-0000-0000-0000-{len(self.devices) + 1:012d}"
            self.devices.append(device)
            return device
        if self.failure:
            self.failure(args)
        if args[0] == "launch":
            self.active_mode = ("ride" if "--review-ride" in args else
                                "companion" if "--companion-visual-check" in args else "home")
            self.theme = "light" if "--review-light" in args else "default"
            self.landscape = "--review-landscape" in args
            return self.launch_result
        if args[0] == "terminate":
            self.active_mode = None
        if args[:1] == ("ui",) and args[2] == "content_size":
            self.content_size = args[3]
        if args[0] == "io":
            marker = f"{args[1]}|mode:{self.active_mode}|size:{self.content_size}|theme:{self.theme}|".encode()
            screenshot(Path(args[-1]), marker=marker,
                       dimensions=(2532, 1170) if self.landscape else (1170, 2532))
        return ""

    def execute(self):
        with patch.object(CAPTURE, "run", side_effect=self.fake_run), patch.object(CAPTURE.time, "sleep"):
            CAPTURE.capture(self.app, self.output)

    def test_real_required_steps_run_without_redundant_global_appearance(self):
        self.execute()
        self.assertEqual(len(self.devices), 1)
        self.assertEqual({image.name for image in self.output.glob("*.png")}, set(CAPTURE.SCREENSHOT_NAMES))
        commands = [args[0] for args in self.calls]
        self.assertIn("install", commands)
        self.assertIn("launch", commands)
        self.assertIn(("ui", self.devices[0], "content_size", "accessibility-large"), self.calls)
        self.assertFalse(any("appearance" in args or args[0] == "status_bar" for args in self.calls))

    def test_companion_relaunch_resets_text_size_and_preserves_home_captures(self):
        self.execute()
        device = self.devices[0]
        terminate = self.calls.index(("terminate", device, "org.koltenberg.MotoLink"))
        reset = self.calls.index(("ui", device, "content_size", "large"))
        launch = self.calls.index(("launch", device, "org.koltenberg.MotoLink", "--companion-visual-check"))
        self.assertLess(terminate, reset)
        self.assertLess(reset, launch)
        for name, mode, size in [
            ("simulator-home.png", "home", "large"),
            ("simulator-large-text.png", "home", "accessibility-large"),
            ("simulator-companion.png", "companion", "large"),
            ("simulator-companion-large-text.png", "companion", "accessibility-large"),
        ]:
            self.assertIn(f"mode:{mode}|size:{size}|".encode(), (self.output / name).read_bytes())

    def test_ride_variants_are_fresh_processes_with_normal_text_and_real_orientation(self):
        self.execute()
        expected = [
            ("simulator-garage-light.png", "home", "light", False),
            ("simulator-ride.png", "ride", "default", False),
            ("simulator-ride-light.png", "ride", "light", False),
            ("simulator-ride-landscape.png", "ride", "default", True),
        ]
        for name, mode, theme, landscape in expected:
            image = self.output / name
            self.assertIn(f"mode:{mode}|size:large|theme:{theme}|".encode(), image.read_bytes())
            width, height = CAPTURE.validate_png(image)
            self.assertEqual(width > height, landscape)
        # Termination must precede each new launch; otherwise iOS ignores new
        # arguments and a screenshot could silently show a previous screen.
        process_running = False
        for call in self.calls:
            if call[0] == "launch":
                self.assertFalse(process_running, "relaunch reused an existing app process")
                process_running = True
            elif call[0] == "terminate":
                process_running = False

    def test_unapplied_landscape_rotation_rejects_entire_set_not_portrait_as_landscape(self):
        def fail(args):
            if args[0] == "io" and Path(args[-1]).name == "simulator-ride-landscape.png":
                self.landscape = False
        self.failure = fail
        self.output.mkdir()
        for name in CAPTURE.SCREENSHOT_NAMES:
            screenshot(self.output / name)
        with self.assertRaisesRegex(CAPTURE.CaptureError, "Landscape rotation was not applied"):
            self.execute()
        self.assertEqual(len(self.devices), 2)
        self.assertEqual(list(self.output.glob("*.png")), [])
        for device in self.devices:
            self.assertIn(("delete", device), self.calls)

    def test_last_ride_launch_failure_does_not_publish_earlier_seven_views(self):
        def fail(args):
            if args[0] == "launch" and "--review-landscape" in args:
                raise CAPTURE.CaptureError("ride landscape launch failed")
        self.failure = fail
        with self.assertRaisesRegex(CAPTURE.CaptureError, "ride landscape launch failed"):
            self.execute()
        self.assertEqual(list(self.output.glob("*.png")), [])
        self.assertFalse(any(args[0] == "io" and
                             Path(args[-1]).name == "simulator-ride-landscape.png"
                             for args in self.calls))

    def test_companion_failure_retries_all_captures_without_publishing_partial_home(self):
        def fail(args):
            if args[0] == "io" and Path(args[-1]).name == "simulator-companion-large-text.png":
                raise CAPTURE.CaptureError("companion screenshot failed")
        self.failure = fail
        self.output.mkdir()
        for name in CAPTURE.SCREENSHOT_NAMES:
            screenshot(self.output / name)
        with self.assertRaisesRegex(CAPTURE.CaptureError, "companion screenshot failed"):
            self.execute()
        self.assertEqual(len(self.devices), 2)
        self.assertEqual(list(self.output.glob("*.png")), [])
        for device in self.devices:
            self.assertIn(("delete", device), self.calls)

    def test_failed_companion_launch_cannot_capture_the_previous_home_process(self):
        def fail(args):
            if args[0] == "launch" and "--companion-visual-check" in args:
                self.launch_result = ""
            elif args[0] == "launch":
                self.launch_result = "org.koltenberg.MotoLink: 1234"
        self.failure = fail
        with self.assertRaisesRegex(CAPTURE.CaptureError, "Companion launch did not return a process ID"):
            self.execute()
        self.assertFalse(any(args[0] == "io" and "companion" in Path(args[-1]).name for args in self.calls))
        self.assertEqual(list(self.output.glob("*.png")), [])

    def test_boot_timeout_gets_one_fresh_simulator_then_all_checks(self):
        def fail(args):
            if args[0] == "bootstatus" and args[1] == self.devices[0]:
                raise subprocess.TimeoutExpired("bootstatus", 150)
        self.failure = fail
        self.execute()
        self.assertEqual(len(self.devices), 2)
        for device in self.devices:
            self.assertIn(("shutdown", device), self.calls)
            self.assertIn(("delete", device), self.calls)
        self.assertIn(self.devices[1].encode(), (self.output / "simulator-home.png").read_bytes())

    def test_second_failure_stays_failure_and_publishes_no_screenshots(self):
        def fail(args):
            if args[0] == "launch":
                raise CAPTURE.CaptureError("application launch failed")
        self.failure = fail
        self.output.mkdir()
        screenshot(self.output / "simulator-home.png")  # Stale output cannot masquerade as success.
        with self.assertRaisesRegex(CAPTURE.CaptureError, "application launch failed"):
            self.execute()
        self.assertEqual(len(self.devices), 2)
        self.assertEqual(list(self.output.glob("*.png")), [])

    def test_shutdown_timeout_preserves_failure_and_still_attempts_delete(self):
        def fail(args):
            if args[0] == "boot":
                raise CAPTURE.CaptureError("original boot failure")
            if args[0] == "shutdown":
                raise subprocess.TimeoutExpired("shutdown", 10)
        self.failure = fail
        with self.assertRaisesRegex(CAPTURE.CaptureError, "original boot failure"):
            self.execute()
        for device in self.devices:
            self.assertIn(("delete", device), self.calls)

    def test_partial_first_attempt_cannot_mix_with_successful_images(self):
        def fail(args):
            if args[0] == "ui" and args[1] == self.devices[0]:
                raise subprocess.TimeoutExpired("content_size", 30)
        self.failure = fail
        self.execute()
        for image in self.output.glob("*.png"):
            self.assertIn(self.devices[1].encode(), image.read_bytes())
            self.assertNotIn(self.devices[0].encode(), image.read_bytes())

    def test_successful_command_without_launch_pid_is_not_success(self):
        self.launch_result = ""
        with self.assertRaisesRegex(CAPTURE.CaptureError, "process ID"):
            self.execute()
        self.assertEqual(len(self.devices), 2)
        self.assertEqual(list(self.output.glob("*.png")), [])

    def test_missing_and_truncated_images_fail_validation(self):
        image = self.root / "missing.png"
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.validate_png(image)
        screenshot(image)
        self.assertEqual(CAPTURE.validate_png(image), (1170, 2532))
        image.write_bytes(image.read_bytes()[:-8])
        with self.assertRaisesRegex(CAPTURE.CaptureError, "Truncated"):
            CAPTURE.validate_png(image)

    def test_expired_global_budget_does_not_issue_another_command(self):
        with patch.object(CAPTURE.time, "monotonic", return_value=100), \
             patch.object(CAPTURE.subprocess, "run") as process:
            with self.assertRaisesRegex(CAPTURE.CaptureError, "budget exhausted"):
                CAPTURE.run("boot", "simulator", deadline=99)
            process.assert_not_called()


class DeviceSelectionTests(unittest.TestCase):
    def test_current_iphone_wins_even_when_previous_type_appears_first(self):
        previous = {"name": "iPhone 16", "identifier": "iphone16", "minRuntimeVersionString": "18.0"}
        current = {"name": "iPhone 17", "identifier": "iphone17", "minRuntimeVersionString": "26.0"}
        selected = CAPTURE.select_device_type([previous, current])
        self.assertIs(selected, current)

    def test_older_xcode_uses_observed_previous_iphone_type(self):
        previous = {"name": "iPhone 16", "identifier": "iphone16"}
        self.assertIs(CAPTURE.select_device_type([{"name": "iPad Air"}, previous]), previous)

    def test_absent_supported_iphone_types_fails_instead_of_inventing_identifier(self):
        for types in ([], [{"name": "iPad Air"}], [{"name": "iPhone 17 Pro"}]):
            with self.subTest(types=types):
                with self.assertRaisesRegex(CAPTURE.CaptureError, "Neither iPhone 17 nor iPhone 16"):
                    CAPTURE.select_device_type(types)


class RuntimeSelectionTests(unittest.TestCase):
    info = {"DTSDKName": "iphonesimulator18.5", "MinimumOSVersion": "16.0"}
    device = {"name": "iPhone 16", "minRuntimeVersionString": "18.0.0"}

    def runtime(self, version, available=True):
        return {"identifier": "ios-" + version, "name": "iOS " + version,
                "version": version, "isAvailable": available}

    def test_sdk_match_wins_over_globally_newest_runtime(self):
        selected = CAPTURE.select_runtime(self.info, [self.runtime("18.4"),
            self.runtime("18.5"), self.runtime("26.2")], self.device)
        self.assertEqual(selected, "ios-18.5")

    def test_closest_older_runtime_is_used_if_exact_sdk_is_missing(self):
        selected = CAPTURE.select_runtime(self.info, [self.runtime("18.0"),
            self.runtime("18.4.1"), self.runtime("26.2")], self.device)
        self.assertEqual(selected, "ios-18.4.1")

    def test_only_newer_runtime_fails_instead_of_silently_selecting_it(self):
        with self.assertRaisesRegex(CAPTURE.CaptureError, "install a matching runtime"):
            CAPTURE.select_runtime(self.info, [self.runtime("26.2")], self.device)

    def test_app_minimum_is_enforced_even_when_sdk_matches(self):
        info = {"DTSDKName": "iphonesimulator18.5", "MinimumOSVersion": "18.5"}
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.select_runtime(info, [self.runtime("18.4")], self.device)

    def test_device_minimum_excludes_old_os_that_cannot_boot_selected_iphone(self):
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.select_runtime(self.info, [self.runtime("17.5")], self.device)

    def test_unavailable_exact_match_does_not_hide_available_older_runtime(self):
        selected = CAPTURE.select_runtime(self.info, [self.runtime("18.5", False),
            self.runtime("18.4")], self.device)
        self.assertEqual(selected, "ios-18.4")

    def test_invalid_or_physical_device_sdk_is_rejected(self):
        for sdk in [None, "iphoneos18.5", "iphonesimulatorbad"]:
            with self.assertRaises(CAPTURE.CaptureError):
                CAPTURE.select_runtime({**self.info, "DTSDKName": sdk}, [self.runtime("18.5")], self.device)

    def test_malformed_runtime_is_logged_and_skipped(self):
        selected = CAPTURE.select_runtime(self.info, [self.runtime("unknown"),
            self.runtime("18.5.0")], self.device)
        self.assertEqual(selected, "ios-18.5.0")


if __name__ == "__main__":
    unittest.main()
