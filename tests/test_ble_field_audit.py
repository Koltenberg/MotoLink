import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ble_audit", ROOT / "scripts/audit-ble-fields.py")
audit_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_module)
LAYOUTS = json.loads((ROOT / "research-v03/audit-layout.json").read_text())


def rx(data):
    return json.dumps({"diagnostic": {"kind": "rx", "hex": bytes(data).hex()}})


def cap(opcode=0x40):
    b = bytearray([255] * 35)
    b[:7] = bytes([opcode, 32, 0, opcode, 0, 5, 0x13])
    b[14] = 1
    return b


class FieldAuditTests(unittest.TestCase):
    def test_placeholder_stream_does_not_become_sensor_data(self):
        report = audit_module.audit([rx([0x4B, 42, 1] + [255] * 42)], LAYOUTS)
        frame = report["telemetryByOpcodeAndLength"]["4B/45"]
        self.assertEqual(frame["payloadAllFFPackets"], 1)
        self.assertEqual(frame["allFFPayloadRangesInclusive"], [[3, 44]])
        self.assertEqual(frame["varyingPayloadOffsets"], [])
        self.assertEqual(frame["blockHeaderNotFFPacketsByOffset"], {})

    def test_sequence_is_not_reported_as_a_changing_sensor(self):
        first = [0x4A, 12, 1] + [255] * 12
        second = first.copy()
        second[2] = 2
        second[7] = 0
        report = audit_module.audit([rx(first), rx(second)], LAYOUTS)
        self.assertEqual(report["telemetryByOpcodeAndLength"]["4A/15"]["varyingPayloadOffsets"],
                         [{"offset": 7, "distinctByteValues": 2}])

    def test_lengths_and_corrupt_lines_are_preserved_as_counts(self):
        report = audit_module.audit(["\n", "{", rx([0x4A, 82, 0]),
            '{"diagnostic":{"kind":"rx","hex":"not hex"}}'], LAYOUTS)
        self.assertEqual(report["counts"]["invalidJSONRecords"], 1)
        self.assertEqual(report["counts"]["invalidHexRecords"], 1)
        self.assertEqual(report["counts"]["invalidLengthRecords"], 1)
        self.assertEqual(report["telemetryByOpcodeAndLength"], {})

    def test_capability_gates_are_field_specific(self):
        b = cap()
        b[9] = 0xD4  # injection=1, wheel=1, RPM=0, boost pressure=3
        report = audit_module.audit([rx(b)], LAYOUTS)["capabilitySnapshots"]["40"]
        self.assertEqual(report["validSnapshots"], 1)
        self.assertEqual(report["observedModes"]["engine_speed"], {"0": 1})
        self.assertEqual(report["observedModes"]["fuel_injection"], {"1": 1})
        self.assertEqual(report["observedModes"]["boost_pressure"], {"3": 1})

    def test_incomplete_and_absent_config_are_not_validated(self):
        b = cap()
        b[14] = 0
        absent = bytearray([255] * 35)
        absent[:4] = bytes([0x40, 32, 0, 0x40])
        report = audit_module.audit([rx(b), rx(absent)], LAYOUTS)["capabilitySnapshots"]["40"]
        self.assertEqual(report["invalidSnapshots"], 1)
        self.assertEqual(report["absentBlockSnapshots"], 1)
        self.assertEqual(report["validSnapshots"], 0)
        self.assertEqual(report["observedModes"], {})

    def test_service_and_tuning_config_use_their_own_lengths(self):
        service = cap(0x1D)[:15]
        service[1] = 12
        tuning = cap(0x47)[:25]
        tuning[1] = 22
        result = audit_module.audit([rx(service), rx(tuning)], LAYOUTS)["capabilitySnapshots"]
        self.assertEqual(result["1D"]["validSnapshots"], 1)
        self.assertEqual(result["47"]["validSnapshots"], 1)
        self.assertIn("oil_change_notify", result["1D"]["observedModes"])
        self.assertIn("ktrc", result["47"]["observedModes"])

    def test_any_incomplete_block_invalidates_config(self):
        b = cap()
        b[15:17] = bytes([5, 0x13])
        b[24] = 0
        self.assertIsNone(audit_module.config_modes(b, LAYOUTS["infoConfig"]))

    def test_variable_length_frames_remain_separate(self):
        report = audit_module.audit([rx([0x45, 52, 0] + [255] * 52),
            rx([0x45, 62, 0] + [0] * 62)], LAYOUTS)
        self.assertEqual(set(report["telemetryByOpcodeAndLength"]), {"45/55", "45/65"})

    def test_personal_data_and_arbitrary_payloads_are_not_emitted(self):
        records = [json.dumps({"kind": "gps", "latitude": 42.123456, "id": "PRIVATE-ID"}),
            json.dumps({"diagnostic": {"kind": "rx", "hex": "030201ABCD", "detail": "PRIVATE-NAME"}}),
            json.dumps({"diagnostic": {"kind": "tx", "hex": "010000"}})]
        report = audit_module.audit(records, LAYOUTS)
        encoded = json.dumps(report)
        for secret in ("42.123456", "PRIVATE-ID", "PRIVATE-NAME", "030201ABCD"):
            self.assertNotIn(secret, encoded)
        self.assertEqual(report["validFrameCountsByOpcode"], {"03": 1})
        self.assertEqual(report["telemetryByOpcodeAndLength"], {})


if __name__ == "__main__":
    unittest.main()
