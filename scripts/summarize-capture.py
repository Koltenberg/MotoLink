#!/usr/bin/env python3
"""Read a MotoLink capture in bounded memory; do not print routes or BLE identifiers."""
import argparse
from collections import Counter
import json
from pathlib import Path


def summarize(path):
    kinds, bluetooth, opcodes, lifecycle = Counter(), Counter(), Counter(), Counter()
    manifest = None
    invalid = 0
    footer = False
    raw = 0
    with Path(path).open(encoding="utf-8-sig") as stream:
        for line in stream:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("Not an object")
            except (ValueError, TypeError):
                invalid += 1
                continue
            kind = record.get("kind")
            if not isinstance(kind, str):
                invalid += 1
                continue
            kinds[kind] += 1
            if kind == "capture_manifest":
                manifest = record
            elif kind == "capture_end":
                footer = True
            elif kind == "diagnostic":
                event = record.get("diagnostic")
                if not isinstance(event, dict):
                    invalid += 1
                    continue
                raw += 1
                event_kind = event.get("kind", "unknown")
                if isinstance(event_kind, str):
                    bluetooth[event_kind] += 1
                if event_kind == "rx":
                    value = event.get("hex")
                    try:
                        packet = bytes.fromhex(value) if isinstance(value, str) else b""
                        opcodes[f"{packet[0]:02X}" if packet else "empty"] += 1
                    except ValueError:
                        opcodes["invalid_hex"] += 1
            elif kind == "lifecycle" and record.get("detail") in ("background", "foreground", "memory_warning", "protected_data_unavailable"):
                lifecycle[record["detail"]] += 1
    if not manifest or manifest.get("schema") != "motolink.capture/1":
        raise ValueError("Capture manifest missing or unsupported schema")
    expected = manifest.get("rawEventsIncluded")
    ride = manifest.get("ride") or {}
    return {
        "schema": "motolink.capture-summary/1",
        "records": dict(kinds), "bluetoothEvents": dict(bluetooth),
        "receivedFirstBytesNotDecoded": dict(opcodes), "lifecycleEvents": dict(lifecycle),
        "invalidLinesOrRecords": invalid, "exportFooterPresent": footer,
        "rawEventsFound": raw, "rawEventsExpected": expected,
        "rawEventCountMatches": raw == expected if isinstance(expected, int) else None,
        "rideFinished": bool(ride.get("endedAt")),
        "gpsPoints": kinds["gps"], "gpsObservations": kinds["gps_observation"],
        "gpsGaps": kinds["gps_gap"],
        "note": "BLE packets do not prove engine state. Background events do not prove uninterrupted recording.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.capture), ensure_ascii=False, indent=2))
