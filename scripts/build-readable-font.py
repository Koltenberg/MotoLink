#!/usr/bin/env python3
"""Build the OFL-licensed, static Moto Link Pixel derivative.

python scripts/build-readable-font.py original.ttf output.ttf \
    --source-tree ios/MotoLink --manifest font-coverage.json

Requires fonttools 4.62.1 only while building; the app uses its bundled font.
The original Pixelify Sans or an earlier Moto Link Pixel derivative is accepted.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import string

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.ttGlyphPen import TTGlyphPen


PATTERNS = {
    "0": ["01110", "10001", "10001", "10101", "10001", "10001", "01110"],
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "Zz": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "Vv": ["10001", "10001", "10001", "10001", "01010", "01010", "00100"],
    "Ыы": ["10000001", "10000001", "10000001", "11110001", "10001001", "10001001", "11110001"],
}
SYMBOLS = {
    "₽": ["1111100", "1000010", "1000010", "1111100", "1000000", "1111000", "1000000"],
    "↑": ["00100", "01110", "10101", "00100", "00100", "00100", "00100"],
    "↓": ["00100", "00100", "00100", "00100", "10101", "01110", "00100"],
    "→": ["0001000", "0000100", "0000010", "1111111", "0000010", "0000100", "0001000"],
    "∅": ["0011110", "0100011", "1000101", "1001001", "1010001", "1100010", "0111100"],
}
CYRILLIC = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя"


def pixel_glyph(rows, bounds):
    left, bottom, right, top = bounds
    width, height = right - left, top - bottom
    pen = TTGlyphPen(None)
    for row, pixels in enumerate(rows):
        for col, pixel in enumerate(pixels):
            if pixel != "1":
                continue
            x0 = round(left + width * col / len(pixels))
            x1 = round(left + width * (col + 1) / len(pixels))
            y0 = round(bottom + height * (len(rows) - row - 1) / len(rows))
            y1 = round(bottom + height * (len(rows) - row) / len(rows))
            pen.moveTo((x0, y0))
            pen.lineTo((x0, y1))
            pen.lineTo((x1, y1))
            pen.lineTo((x1, y0))
            pen.closePath()
    return pen.glyph()


def map_character(font, character, glyph_name):
    for table in font["cmap"].tables:
        if table.isUnicode():
            table.cmap[ord(character)] = glyph_name


def source_characters(source_tree):
    """Conservative coverage, including non-UI Swift string literals."""
    required = set(string.printable) - set("\t\n\r\v\f")
    required.update(CYRILLIC)
    required.update(SYMBOLS)
    for path in sorted(Path(source_tree).rglob("*.swift")) if source_tree else []:
        for literal in re.findall(r'"(?:\\.|[^"\\])*"', path.read_text(encoding="utf-8")):
            required.update(c for c in literal if c.isprintable())
    return required


def build(input_path, output_path, source_tree=None, manifest_path=None):
    input_path, output_path = Path(input_path), Path(output_path)
    source_hash = hashlib.sha256(input_path.read_bytes()).hexdigest()
    font = TTFont(input_path, recalcTimestamp=False)
    if "fvar" in font:
        font = instantiateVariableFont(font, {
            axis.axisTag: axis.defaultValue for axis in font["fvar"].axes
        })
    cmap = font.getBestCmap()
    # Visually verified upright Cyrillic forms already exist in the source.
    map_character(font, "О", cmap[ord("O")])
    map_character(font, "П", cmap[ord("Π")])
    # Source U+041A mistakenly includes an acute accent; upright Latin K has
    # the same Cyrillic outline without the stray mark (631 rather than 837).
    map_character(font, "К", cmap[ord("K")])
    for characters, rows in PATTERNS.items():
        for character in characters:
            name = cmap[ord(character)]
            original = font["glyf"][name]
            original.recalcBounds(font["glyf"])
            bounds = original.xMin, original.yMin, original.xMax, original.yMax
            font["glyf"][name] = pixel_glyph(rows, bounds)

    reference = font["glyf"][cmap[ord("O")]]
    symbol_bounds = reference.xMin, reference.yMin, reference.xMax, reference.yMax
    symbol_metrics = font["hmtx"][cmap[ord("O")]]
    glyph_order = font.getGlyphOrder()
    for character, rows in SYMBOLS.items():
        name = "uni%04X" % ord(character)
        if name not in glyph_order:
            glyph_order.append(name)
        font["glyf"][name] = pixel_glyph(rows, symbol_bounds)
        font["hmtx"][name] = symbol_metrics
        map_character(font, character, name)
    font.setGlyphOrder(glyph_order)

    # The source has no tnum feature; equalize the actual decimal advances.
    advance = font["hmtx"][cmap[ord("0")]][0]
    for digit in string.digits:
        name = cmap[ord(digit)]
        old_advance, left_bearing = font["hmtx"][name]
        shift = (advance - old_advance) // 2
        if shift:
            glyph = font["glyf"][name]
            if glyph.isComposite():
                raise ValueError("Expected simple decimal outline: " + digit)
            glyph.coordinates.translate((shift, 0))
            glyph.recalcBounds(font["glyf"])
        font["hmtx"][name] = (advance, left_bearing + shift)

    replacements = {
        1: "Moto Link Pixel", 2: "Regular", 3: "MotoLinkPixel-Regular-1.1",
        4: "Moto Link Pixel Regular", 5: "Version 1.100",
        6: "MotoLinkPixel-Regular", 16: "Moto Link Pixel", 17: "Regular",
    }
    for record in list(font["name"].names):
        if record.nameID in replacements:
            font["name"].setName(replacements[record.nameID], record.nameID,
                                 record.platformID, record.platEncID, record.langID)
    # A fixed release timestamp makes same-input builds reproducible.
    font["head"].modified = 3873312000  # 2026-09-27 UTC, Mac epoch.
    required = source_characters(source_tree)
    missing = sorted(c for c in required if ord(c) not in font.getBestCmap())
    if missing:
        raise ValueError("Missing app characters: " + repr("".join(missing)))
    font.save(output_path)
    # Check compiled output as well as the mutable in-memory font.
    compiled = TTFont(output_path, recalcTimestamp=False)
    compiled_cmap = compiled.getBestCmap()
    widths = {digit: compiled["hmtx"][compiled_cmap[ord(digit)]][0]
              for digit in string.digits}
    if set(widths.values()) != {advance}:
        raise ValueError("Decimal advances are not tabular: " + repr(widths))
    if any(ord(c) not in compiled_cmap for c in required):
        raise ValueError("Compiled font lost required characters")
    manifest = {
        "family": "Moto Link Pixel", "version": "1.100",
        "sourceSHA256": source_hash,
        "sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
        "bytes": output_path.stat().st_size,
        "unitsPerEm": compiled["head"].unitsPerEm,
        "unicodeMappings": len(compiled_cmap),
        "requiredCharacters": "".join(sorted(required)),
        "requiredCharacterCount": len(required), "missingCharacters": [],
        "decimalAdvances": widths,
        "aliases": {"О": "O", "П": "Π", "К": "K"},
        "newPixelSymbols": "".join(SYMBOLS),
        "redrawnCharacters": "".join(PATTERNS),
    }
    if manifest_path:
        Path(manifest_path).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--source-tree")
    parser.add_argument("--manifest")
    arguments = parser.parse_args()
    build(arguments.input, arguments.output, arguments.source_tree, arguments.manifest)


if __name__ == "__main__":
    main()
