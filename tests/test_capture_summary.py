import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("capture", Path(__file__).parents[1] / "scripts/summarize-capture.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureSummaryTests(unittest.TestCase):
    def run_capture(self, rows, tail=""):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ride.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n" + tail, encoding="utf-8")
            return capture.summarize(path)

    def test_unknown_packets_and_no_gps_are_still_useful(self):
        result = self.run_capture([
            {"kind": "capture_manifest", "schema": "motolink.capture/1", "rawEventsIncluded": 2, "ride": {"endedAt": "2026-09-20T13:00:00Z"}},
            {"kind": "diagnostic", "diagnostic": {"kind": "rx", "hex": "FF00"}},
            {"kind": "diagnostic", "diagnostic": {"kind": "error", "detail": "private name"}},
            {"kind": "gps_gap"}, {"kind": "capture_end"},
        ])
        self.assertTrue(result["rawEventCountMatches"])
        self.assertEqual(result["receivedFirstBytesNotDecoded"], {"FF": 1})
        self.assertEqual(result["gpsPoints"], 0)
        self.assertNotIn("private name", json.dumps(result))

    def test_truncated_export_reports_missing_data(self):
        result = self.run_capture([
            {"kind": "capture_manifest", "schema": "motolink.capture/1", "rawEventsIncluded": 5},
            {"kind": "gps", "point": {"latitude": 55, "longitude": 37}},
        ], '{"kind":')
        self.assertFalse(result["rawEventCountMatches"])
        self.assertFalse(result["exportFooterPresent"])
        self.assertEqual(result["invalidLinesOrRecords"], 1)
        self.assertEqual(result["gpsPoints"], 1)

    def test_unrelated_file_is_not_a_valid_capture(self):
        with self.assertRaises(ValueError):
            self.run_capture([{"kind": "rx"}])


if __name__ == "__main__":
    unittest.main()
