"""Infrastructure regression checks; no simulator, Apple account or phone used."""
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

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
        self.runner_env = {}
        self.seed_devices = {}
        self.clone_result = None
        self.container = self.root / "app-data"
        (self.container / "Documents").mkdir(parents=True)
        self.orientation_file = self.container / "Documents" / CAPTURE.ORIENTATION_EVIDENCE
        self.write_orientation = True
        self.orientation_override = {}

    def fake_run(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ("list", "runtimes"):
            return json.dumps({"runtimes": [{"identifier": "runtime-ios", "isAvailable": True,
                                            "name": "iOS 18.5", "version": "18.5"}]})
        if args[:2] == ("list", "devicetypes"):
            return json.dumps({"devicetypes": [{"name": "iPhone 16", "identifier": "iphone16"}]})
        if args[:2] == ("list", "devices"):
            return json.dumps({"devices": self.seed_devices})
        if args[0] == "get_app_container":
            return str(self.container)
        if args[0] in ("create", "clone"):
            device = (self.clone_result if args[0] == "clone" and self.clone_result else
                      f"00000000-0000-0000-0000-{len(self.devices) + 1:012d}")
            self.devices.append(device)
            return device
        if self.failure:
            self.failure(args)
        if args[0] == "launch":
            self.active_mode = ("ride" if "--review-ride" in args else
                                "companion" if "--companion-visual-check" in args else "home")
            self.theme = "light" if "--review-light" in args else "default"
            self.landscape = "--review-landscape" in args
            if self.landscape and self.write_orientation:
                self.orientation_file.write_text(json.dumps({
                    "interfaceLandscape": True, "interfaceOrientation": 3,
                    "windowWidth": 844, "windowHeight": 390,
                    "sceneWidth": 844, "sceneHeight": 390,
                    "error": None, "capturedAt": time.time(), **self.orientation_override,
                }), encoding="utf-8")
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
        with patch.object(CAPTURE, "run", side_effect=self.fake_run), \
             patch.object(CAPTURE.time, "sleep"), patch.dict(CAPTURE.os.environ, self.runner_env, clear=True):
            CAPTURE.capture(self.app, self.output)

    def set_hosted_seed(self):
        self.runner_env = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}
        seed = {"udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "name": "iPhone 16",
                "deviceTypeIdentifier": "iphone16", "isAvailable": True, "state": "Shutdown"}
        self.seed_devices = {"runtime-ios": [seed]}
        return seed["udid"]

    def test_hosted_capture_clones_source_without_booting_or_deleting_it(self):
        seed = self.set_hosted_seed()
        self.execute()
        self.assertIn(("clone", seed, "MotoLink visual check 1"), self.calls)
        self.assertFalse(any(call[0] == "create" for call in self.calls))
        for call in self.calls:
            if call[0] != "clone":
                self.assertNotIn(seed, call)
        self.assertIn(("delete", self.devices[0]), self.calls)

    def test_no_seed_on_hosted_runner_falls_back_to_new_device(self):
        self.runner_env = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}
        self.execute()
        self.assertTrue(any(call[0] == "create" for call in self.calls))
        self.assertFalse(any(call[0] == "clone" for call in self.calls))

    def test_self_hosted_or_local_capture_never_reads_or_clones_user_devices(self):
        for env in ({}, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},
                    {"RUNNER_ENVIRONMENT": "github-hosted"}):
            with self.subTest(env=env):
                self.calls = []
                self.runner_env = env
                self.execute()
                self.assertFalse(any(call[:2] == ("list", "devices") or call[0] == "clone"
                                     for call in self.calls))

    def test_clone_returning_source_uuid_cannot_trigger_source_cleanup(self):
        seed = self.set_hosted_seed()
        self.clone_result = seed
        with self.assertRaisesRegex(CAPTURE.CaptureError, "did not return a new device UUID"):
            self.execute()
        self.assertFalse(any(call[0] in ("boot", "shutdown", "delete", "install")
                             for call in self.calls))

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
        self.orientation_override = {"interfaceLandscape": False, "interfaceOrientation": 1,
                                     "windowWidth": 390, "windowHeight": 844,
                                     "sceneWidth": 390, "sceneHeight": 844}
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
        for attempt in (1, 2):
            debug = self.output / f"debug-attempt{attempt}"
            self.assertEqual(len(list(debug.glob("*.png"))), 8)
            manifest = json.loads((debug / "failure.json").read_text())
            self.assertEqual(manifest["status"], "failed")
            self.assertIn("Landscape rotation was not applied", manifest["error"])
            self.assertFalse(json.loads((debug / CAPTURE.ORIENTATION_EVIDENCE).read_text())["interfaceLandscape"])
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
        for attempt in (1, 2):
            debug = self.output / f"debug-attempt{attempt}"
            self.assertEqual(len(list(debug.glob("*.png"))), 7)
            self.assertEqual(json.loads((debug / "failure.json").read_text())["status"], "failed")
        self.assertFalse(any(args[0] == "io" and
                             Path(args[-1]).name == "simulator-ride-landscape.png"
                             for args in self.calls))

    def test_headless_portrait_pixels_pass_only_with_fresh_landscape_scene_evidence(self):
        def keep_physical_display_portrait(args):
            if args[0] == "io" and Path(args[-1]).name == "simulator-ride-landscape.png":
                self.landscape = False
        self.failure = keep_physical_display_portrait
        self.execute()
        self.assertEqual(CAPTURE.validate_png(self.output / "simulator-ride-landscape.png"), (1170, 2532))
        evidence = json.loads((self.output / CAPTURE.ORIENTATION_EVIDENCE).read_text())
        self.assertTrue(evidence["interfaceLandscape"])
        self.assertGreater(evidence["windowWidth"], evidence["windowHeight"])

    def test_previous_geometry_is_deleted_and_missing_new_evidence_fails(self):
        self.orientation_file.write_text('{"interfaceLandscape":true}', encoding="utf-8")
        self.write_orientation = False
        with self.assertRaisesRegex(CAPTURE.CaptureError, "Missing landscape geometry evidence"):
            self.execute()
        self.assertFalse(self.orientation_file.exists())
        self.assertEqual(list(self.output.glob("*.png")), [])
        self.assertFalse((self.output / CAPTURE.ORIENTATION_EVIDENCE).exists())

    def test_corrupt_new_geometry_is_retained_for_diagnosis_and_fails(self):
        def corrupt_evidence(args):
            if args[0] == "io" and Path(args[-1]).name == "simulator-ride-landscape.png":
                self.orientation_file.write_text("{broken", encoding="utf-8")
        self.failure = corrupt_evidence
        with self.assertRaisesRegex(CAPTURE.CaptureError, "invalid landscape geometry evidence"):
            self.execute()
        self.assertEqual(list(self.output.glob("*.png")), [])
        self.assertEqual((self.output / "debug-attempt1" / CAPTURE.ORIENTATION_EVIDENCE).read_text(), "{broken")

    def test_stale_geometry_or_rejected_request_cannot_validate_landscape(self):
        for override, message in [
            ({"capturedAt": time.time() - 3600}, "does not belong to this launch"),
            ({"error": "request denied"}, "Landscape rotation was not applied"),
            ({"sceneWidth": float("nan")}, "Landscape rotation was not applied"),
            ({"windowWidth": 0}, "Landscape rotation was not applied"),
        ]:
            with self.subTest(override=override):
                self.orientation_override = override
                with self.assertRaisesRegex(CAPTURE.CaptureError, message):
                    self.execute()
                self.assertEqual(list(self.output.glob("*.png")), [])

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
                raise subprocess.TimeoutExpired("bootstatus", 300)
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
        self.assertIn(self.devices[0].encode(),
                      (self.output / "debug-attempt1" / "simulator-home.png").read_bytes())
        self.assertEqual(json.loads((self.output / "debug-attempt1" / "failure.json").read_text())["status"], "failed")

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


class RunnerSeedSelectionTests(unittest.TestCase):
    device_type = {"name": "iPhone 17", "identifier": "iphone17"}
    valid = {"name": "iPhone 17", "deviceTypeIdentifier": "iphone17",
             "udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "state": "Shutdown", "isAvailable": True}

    def test_seed_requires_exact_runtime_type_and_available_stopped_valid_uuid(self):
        variants = [{"deviceTypeIdentifier": "iphone16"}, {"state": "Booted"},
                    {"isAvailable": False}, {"isAvailable": None}, {"udid": "not-a-uuid"},
                    {"name": "MotoLink visual check 1"}]
        candidates = [{**self.valid, **override} for override in variants] + [self.valid]
        selected = CAPTURE.select_runner_seed(
            {"wrong-runtime": [self.valid], "runtime-ios": candidates}, "runtime-ios", self.device_type)
        self.assertEqual(selected, self.valid["udid"])
        self.assertIsNone(CAPTURE.select_runner_seed(
            {"wrong-runtime": [self.valid]}, "runtime-ios", self.device_type))
        self.assertIsNone(CAPTURE.select_runner_seed(
            {"runtime-ios": candidates[:-1]}, "runtime-ios", self.device_type))


class CommandDiagnosticsTests(unittest.TestCase):
    def test_timeout_surfaces_binary_stdout_and_stderr_with_bounded_tail(self):
        error = subprocess.TimeoutExpired("install", 60,
            output=b"discard-me" + b"x" * 9000 + b"Waiting on installd",
            stderr=b"service did not reply\\xff")
        with patch.object(CAPTURE.subprocess, "run", side_effect=error):
            with self.assertRaises(CAPTURE.CaptureError) as raised:
                CAPTURE.run("install", "simulator", "App.app", timeout=60)
        detail = str(raised.exception)
        self.assertIn("\nCaptured stdout:\n", detail)
        self.assertIn("Waiting on installd", detail)
        self.assertIn("service did not reply", detail)
        self.assertNotIn("discard-me", detail)
        self.assertLess(len(detail), 8300)

    def test_boot_progress_inherits_streams_reports_wait_and_does_not_kill_success(self):
        process = Mock()
        process.wait.side_effect = [subprocess.TimeoutExpired("bootstatus", 30), 0]
        process.poll.return_value = 0
        with patch.object(CAPTURE.subprocess, "Popen", return_value=process) as popen, \
             patch.object(CAPTURE.time, "monotonic", side_effect=[0, 0, 30, 30]), \
             patch("builtins.print") as output:
            CAPTURE.boot_with_progress(["xcrun", "simctl", "bootstatus", "simulator", "-b"], 300)
        popen.assert_called_once_with(["xcrun", "simctl", "bootstatus", "simulator", "-b"])
        self.assertTrue(any("after 30s" in str(call) for call in output.call_args_list))
        process.kill.assert_not_called()

    def test_boot_deadline_kills_only_started_client_and_retains_failure(self):
        process = Mock()
        process.wait.side_effect = [subprocess.TimeoutExpired("bootstatus", 30), -9]
        process.poll.return_value = None
        with patch.object(CAPTURE.subprocess, "Popen", return_value=process), \
             patch.object(CAPTURE.time, "monotonic", side_effect=[0, 0, 31, 31]):
            with self.assertRaisesRegex(CAPTURE.CaptureError, "timed out"):
                CAPTURE.run("bootstatus", "simulator", "-b", timeout=30)
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_args_list[-1].kwargs, {"timeout": 5})

    def test_nonzero_boot_result_is_not_treated_as_readiness(self):
        process = Mock()
        process.wait.return_value = 2
        process.poll.return_value = 2
        with patch.object(CAPTURE.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(CAPTURE.CaptureError, r"bootstatus failed \(2\)"):
                CAPTURE.run("bootstatus", "simulator", "-b", timeout=300)


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
