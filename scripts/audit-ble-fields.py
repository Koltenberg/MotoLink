#!/usr/bin/env python3
"""Offline, aggregate-only audit of a native MotoLink JSONL capture.

No Bluetooth/network access. Never emits coordinates, IDs, timestamps, raw
packets or arbitrary event text. No field is decoded into a physical unit.
Byte layouts originate in the Apache-2.0 upstream recorded in audit-layout.json.
See docs/RIDEOLOGY_RESEARCH_2026-09-21.md for evidence and limitations.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TELEMETRY = {0x41, 0x45, 0x4A, 0x4B}
CONFIGS = {0x40: "infoConfig", 0x1D: "serviceConfig", 0x47: "tuningConfig"}
FF_ONLY = 1 << 255


def ranges(indices):
    result = []
    for i in sorted(indices):
        if result and i == result[-1][1] + 1:
            result[-1][1] = i
        else:
            result.append([i, i])
    return result


def config_modes(data, layout):
    # Capability validity is a per-block completion bit, not an ACK result.
    expected = {0x40: 35, 0x1D: 15, 0x47: 25}.get(data[0]) if data else None
    if len(data) != expected or data[1] + 3 != len(data) or data[3] != data[0]:
        return None
    present = False
    for start in range(5, len(data) - 9, 10):
        end = start + 9
        if data[start] != 255 or data[start + 1] != 255:
            present = True
            if data[end] & 1 == 0:
                return None
    if not present:
        return {}
    return {name: (data[offset] & mask) >> shift
            for name, offset, mask, shift in layout}


class FrameStats:
    def __init__(self, size):
        self.count = 0
        self.values = [0] * size
        self.blocks = Counter()
        self.entire_payload_ff = 0

    def add(self, data):
        self.count += 1
        self.entire_payload_ff += all(v == 255 for v in data[3:])
        for i, value in enumerate(data):
            self.values[i] |= 1 << value
        # Headers are ten-byte block positions in the observed BLE5 layouts.
        # Their presence alone does not establish sensor support or validity.
        for i in range(5, len(data) - 1, 10):
            if data[i] != 255 and data[i + 1] != 255:
                self.blocks[i] += 1

    def report(self):
        return {
            "packets": self.count,
            "payloadAllFFPackets": self.entire_payload_ff,
            "allFFPayloadRangesInclusive": ranges(
                i for i, bits in enumerate(self.values) if i >= 3 and bits == FF_ONLY),
            "varyingPayloadOffsets": [
                {"offset": i, "distinctByteValues": bits.bit_count()}
                for i, bits in enumerate(self.values) if i >= 3 and bits.bit_count() > 1],
            "blockHeaderNotFFPacketsByOffset": dict(sorted(self.blocks.items())),
        }


def audit(lines, layouts):
    stats = Counter()
    opcodes = Counter()
    frames = {}
    capabilities = {}
    for line in lines:
        if not line.strip():
            continue
        stats["records"] += 1
        try:
            row = json.loads(line)
        except (ValueError, TypeError):
            stats["invalidJSONRecords"] += 1
            continue
        if not isinstance(row, dict):
            continue
        event = row.get("diagnostic")
        if not isinstance(event, dict) or event.get("kind") != "rx":
            continue
        stats["rxRecords"] += 1
        raw = event.get("hex")
        if not isinstance(raw, str) or len(raw) > 1024:
            stats["invalidHexRecords"] += 1
            continue
        try:
            data = bytes.fromhex(raw)
        except ValueError:
            stats["invalidHexRecords"] += 1
            continue
        if len(data) < 3 or len(data) != data[1] + 3:
            stats["invalidLengthRecords"] += 1
            continue
        opcode = data[0]
        opcodes[f"{opcode:02X}"] += 1
        if opcode in TELEMETRY:
            key = f"{opcode:02X}/{len(data)}"
            if key not in frames:
                frames[key] = FrameStats(len(data))
            frames[key].add(data)
        if opcode in CONFIGS:
            key = f"{opcode:02X}"
            item = capabilities.setdefault(key, {
                "validSnapshots": 0, "invalidSnapshots": 0, "absentBlockSnapshots": 0, "observedModes": {}})
            modes = config_modes(data, layouts[CONFIGS[opcode]])
            if modes is None:
                item["invalidSnapshots"] += 1
                continue
            if not modes:
                item["absentBlockSnapshots"] += 1
                continue
            item["validSnapshots"] += 1
            for name, mode in modes.items():
                item["observedModes"].setdefault(name, Counter())[str(mode)] += 1
    return {
        "schema": "motolink.ble-field-audit/1",
        "counts": dict(stats),
        "validFrameCountsByOpcode": dict(sorted(opcodes.items())),
        "telemetryByOpcodeAndLength": {k: v.report() for k, v in sorted(frames.items())},
        "capabilitySnapshots": capabilities,
        "interpretation": [
            "All-FF ranges describe this capture only, not every mode of the motorcycle.",
            "0xFF has field-specific meaning; for example throttle mode 1 can represent 100%.",
            "Configuration modes are aggregated observations, not a decoder for a later session.",
            "No claim of a physical sensor, unit, support, or successful reconnect follows from a changing byte.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="Native MotoLink JSONL capture")
    parser.add_argument("--output", type=Path, help="Write JSON; otherwise print it")
    args = parser.parse_args()
    layouts = json.loads((ROOT / "research-v03/audit-layout.json").read_text(encoding="utf-8"))
    try:
        with args.capture.open(encoding="utf-8-sig") as source:
            result = audit(source, layouts)
        rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            if args.output.resolve() == args.capture.resolve():
                parser.error("Output must not overwrite the original capture")
            args.output.write_text(rendered, encoding="utf-8")
        else:
            print(rendered, end="")
    except (OSError, UnicodeError):
        print("Cannot read the capture or write the report.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
