"""Small independent audit of wire requests and ACK assumptions.

These tests do not establish EX500G on-bike compatibility. They guard exact
request-only masks and the distinction between ACKs and measurements.
Run: python -m unittest discover -s MotoLink/research-v03 -p 'test_*.py' -v
"""
import json
from pathlib import Path
import unittest


PROFILE = json.loads(Path(__file__).with_name("protocol-profile.json").read_text())


def classify_ack(data, expected):
    if len(data) < 5 or data[0] != 0x20 or len(data) != data[1] + 3:
        return None
    command = data[3]
    if command != expected and not (expected == 0x08 and command == 0x13):
        return None
    # Long ACKs can echo the requested profile or text. No generic status offset.
    if len(data) != 5:
        return {"command": command, "status": None, "kind": "extended-echo"}
    return {"command": command, "status": data[4], "kind": "short-ack"}


class ProtocolProfileAudit(unittest.TestCase):
    def request(self, command):
        return bytes.fromhex(PROFILE["commands"][command]["hex"])

    def test_wire_lengths_and_encoding_match(self):
        for command, item in PROFILE["commands"].items():
            with self.subTest(command=command):
                data = bytes.fromhex(item["hex"])
                self.assertEqual(len(data), data[1] + 3)
                self.assertEqual(list(data), item["bytes"])
                self.assertEqual(len(data), item["length"])

    def test_request_masks_do_not_contain_setting_values(self):
        data = self.request("1B")
        self.assertEqual(data[:8], bytes.fromhex("1b0c00ffff050a00"))
        self.assertEqual(data[8:], b"\xff" * 7)
        data = self.request("48")
        self.assertEqual(data[:8], bytes.fromhex("482a00ffff050900"))
        self.assertEqual(data[8:], b"\xff" * 37)
        data = self.request("1E")
        self.assertEqual(data[:5], bytes.fromhex("1e2a01ffff"))
        for start, block in [(5, 0x0C), (15, 0x0D), (25, 0x0E)]:
            self.assertEqual(data[start:start + 3], bytes([5, block, 0]))
            self.assertEqual(data[start + 3:start + 10], b"\xff" * 7)
        self.assertEqual(data[35:], b"\xff" * 10)

    def test_profile_is_exact_observed_payload(self):
        self.assertEqual(self.request("08").hex(), "080c00ffff0a08017803e800c80064")
        self.assertEqual(self.request("0B")[7:15], b"MotoLink")

    def test_short_ack_matches_only_current_command(self):
        ack = bytes.fromhex("2002934500")
        self.assertEqual(classify_ack(ack, 0x45)["status"], 0)
        self.assertIsNone(classify_ack(ack, 0x41))
        rejected = bytes.fromhex("20029b4201")
        self.assertEqual(classify_ack(rejected, 0x42)["status"], 1)

    def test_long_profile_echo_does_not_become_rejection(self):
        ack = bytes.fromhex("200c9208000a08017803e800c80064")
        self.assertIsNone(classify_ack(ack, 0x08)["status"])
        alias = bytearray(ack)
        alias[3] = 0x13
        self.assertIsNotNone(classify_ack(alias, 0x08))
        self.assertIsNone(classify_ack(alias, 0x45))

    def test_phone_echo_does_not_treat_ascii_as_error(self):
        ack = bytearray(self.request("0B"))
        ack[0], ack[2], ack[3], ack[4] = 0x20, 0x83, 0x0B, 0x00
        self.assertEqual(ack[7], ord("M"))
        self.assertIsNone(classify_ack(ack, 0x0B)["status"])

    def test_short_or_wrong_length_ack_rejected(self):
        for value in ["2002", "20029345", "2001934500", "200293450000"]:
            self.assertIsNone(classify_ack(bytes.fromhex(value), 0x45))


if __name__ == "__main__":
    unittest.main()
