"""Regression checks for the shipped font, using only Python's standard library."""
import hashlib
import json
from pathlib import Path
import re
import struct
import unittest


ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "ios/MotoLink/Fonts/MotoLinkPixel.ttf"


class TrueType:
    def __init__(self, path):
        self.data = path.read_bytes()
        count = self.u16(4)
        self.tables = {}
        for offset in range(12, 12 + count * 16, 16):
            tag, _, start, length = struct.unpack_from(">4sIII", self.data, offset)
            self.tables[tag.decode("ascii")] = (start, length)
        self.cmaps = []
        cmap_start = self.tables["cmap"][0]
        for index in range(self.u16(cmap_start + 2)):
            platform, encoding, relative = struct.unpack_from(">HHI", self.data, cmap_start + 4 + index * 8)
            start = cmap_start + relative
            if platform == 0 or (platform == 3 and encoding in (1, 10)):
                mapping = self.read_cmap(start)
                if mapping:
                    self.cmaps.append(mapping)
        if not self.cmaps:
            raise ValueError("No supported Unicode cmap")
        self.cmap = max(self.cmaps, key=len)

    def u16(self, offset):
        return struct.unpack_from(">H", self.data, offset)[0]

    def read_cmap(self, start):
        format_number = self.u16(start)
        mapping = {}
        if format_number == 4:
            count = self.u16(start + 6) // 2
            ends = start + 14
            starts = ends + count * 2 + 2
            deltas = starts + count * 2
            ranges = deltas + count * 2
            for index in range(count):
                first, last = self.u16(starts + index * 2), self.u16(ends + index * 2)
                delta, distance = self.u16(deltas + index * 2), self.u16(ranges + index * 2)
                for codepoint in range(first, min(last, 0xFFFE) + 1):
                    if distance:
                        glyph = self.u16(ranges + index * 2 + distance + (codepoint - first) * 2)
                        glyph = (glyph + delta) & 0xFFFF if glyph else 0
                    else:
                        glyph = (codepoint + delta) & 0xFFFF
                    if glyph:
                        mapping[codepoint] = glyph
        elif format_number == 12:
            groups = struct.unpack_from(">I", self.data, start + 12)[0]
            for index in range(groups):
                first, last, glyph = struct.unpack_from(">III", self.data, start + 16 + index * 12)
                mapping.update({point: glyph + point - first for point in range(first, last + 1)})
        return mapping

    def advance(self, character):
        count = self.u16(self.tables["hhea"][0] + 34)
        return self.u16(self.tables["hmtx"][0] + min(self.cmap[ord(character)], count - 1) * 4)

    def outline(self, character):
        glyph = self.cmap[ord(character)]
        loca = self.tables["loca"][0]
        if self.u16(self.tables["head"][0] + 50):
            first, last = struct.unpack_from(">II", self.data, loca + glyph * 4)
        else:
            first, last = struct.unpack_from(">HH", self.data, loca + glyph * 2)
            first, last = first * 2, last * 2
        start = self.tables["glyf"][0]
        return self.data[start + first:start + last]


class PixelFontTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.font = TrueType(FONT)

    def test_every_unicode_cmap_covers_russian_and_app_symbols(self):
        required = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя0123456789₽↑↓→∅°·–—…"
        for cmap in self.font.cmaps:
            self.assertEqual([c for c in required if not cmap.get(ord(c))], [])

    def test_all_swift_literal_characters_have_real_glyphs(self):
        missing = {}
        for path in (ROOT / "ios/MotoLink").rglob("*.swift"):
            for literal in re.findall(r'"(?:\\.|[^"\\])*"', path.read_text(encoding="utf-8")):
                absent = {c for c in literal if c.isprintable() and not self.font.cmap.get(ord(c))}
                if absent:
                    missing.setdefault(str(path.relative_to(ROOT)), set()).update(absent)
        self.assertEqual(missing, {})

    def test_decimal_columns_do_not_move_when_one_changes(self):
        widths = [self.font.advance(c) for c in "0123456789"]
        self.assertEqual(len(set(widths)), 1)
        self.assertGreater(widths[0], 0)

    def test_previously_confusable_characters_have_different_outlines(self):
        for first, second in [("0", "O"), ("0", "О"), ("5", "S"), ("2", "Z"), ("V", "U")]:
            with self.subTest(pair=first + second):
                self.assertNotEqual(self.font.outline(first), self.font.outline(second))

    def test_cyrillic_aliases_have_correct_existing_outlines(self):
        self.assertEqual(self.font.outline("О"), self.font.outline("O"))
        self.assertEqual(self.font.outline("П"), self.font.outline("Π"))
        self.assertEqual(self.font.outline("К"), self.font.outline("K"))
        self.assertNotEqual(self.font.outline("П"), self.font.outline("Н"))

    def test_manifest_matches_shipped_binary(self):
        manifest = json.loads((FONT.parent / "coverage.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["sha256"], hashlib.sha256(self.font.data).hexdigest())
        self.assertEqual(manifest["bytes"], len(self.font.data))
        self.assertEqual(manifest["missingCharacters"], [])
        self.assertEqual(manifest["unicodeMappings"], len(self.font.cmap))


if __name__ == "__main__":
    unittest.main()
