#!/usr/bin/env python3
"""Generate the OFL-licensed Moto Link derivative from original Pixelify Sans.

Usage: python build-readable-font.py original.ttf output.ttf
Requires fonttools 4.62.1; runtime app has no font/download dependency.
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.ttGlyphPen import TTGlyphPen

font = TTFont(sys.argv[1])
if "fvar" in font:
    font = instantiateVariableFont(font, {axis.axisTag: axis.defaultValue for axis in font["fvar"].axes})
patterns = {
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "Zz": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "Vv": ["10001", "10001", "10001", "10001", "01010", "01010", "00100"],
    "Ыы": ["10000001", "10000001", "10000001", "11110001", "10001001", "10001001", "11110001"],
}
cmap = font.getBestCmap()
for characters, rows in patterns.items():
    for character in characters:
        name = cmap[ord(character)]
        original = font["glyf"][name]
        left, bottom, width, height = original.xMin, original.yMin, original.xMax-original.xMin, original.yMax-original.yMin
        pen = TTGlyphPen(None)
        for row, pixels in enumerate(rows):
            for col, pixel in enumerate(pixels):
                if pixel != "1":
                    continue
                x0 = round(left + width * col / len(pixels)); x1 = round(left + width * (col + 1) / len(pixels))
                y0 = round(bottom + height * (6 - row) / 7); y1 = round(bottom + height * (7 - row) / 7)
                pen.moveTo((x0, y0)); pen.lineTo((x0, y1)); pen.lineTo((x1, y1)); pen.lineTo((x1, y0)); pen.closePath()
        font["glyf"][name] = pen.glyph()
        # Preserve advance widths/sidebearings and all other Cyrillic glyphs.
for record in list(font["name"].names):
    replacements = {1: "Moto Link Pixel", 2: "Regular", 3: "MotoLinkPixel-Regular-1.0", 4: "Moto Link Pixel Regular",
                    6: "MotoLinkPixel-Regular", 16: "Moto Link Pixel", 17: "Regular"}
    if record.nameID in replacements:
        font["name"].setName(replacements[record.nameID], record.nameID, record.platformID, record.platEncID, record.langID)
font.save(sys.argv[2])
