# Moto Link Pixel

Derived from Pixelify Sans (copyright 2021 The Pixelify Sans Project Authors,
https://github.com/eifetx/Pixelify-Sans), under the accompanying SIL OFL 1.1.

The renamed static regular instance keeps the PostScript name
`MotoLinkPixel-Regular`; no font is downloaded by the app.

The 0.4.7 derivative redrew `5`, `Z/z`, `V/v` and `Ы/ы` on a pixel grid to
distinguish five from S, Z from two, and clarify V and the Cyrillic letter.

Font version 1.100, shipped with Moto Link 0.4.11, additionally:

- Restores missing uppercase Russian `О` and `П` using the visually identical
  source Latin `O` and Greek `Π` outlines, in every Unicode cmap.
- Corrects source uppercase Russian `К`, whose outline mistakenly contained an
  acute accent, using the identical upright Latin `K` without the extra mark.
- Draws `₽`, `↑`, `↓`, `→` and `∅` on a pixel grid matching the capital height.
- Gives `0` a central dot so it differs from Russian `О` and Latin `O`.
- Centers the narrow `1` in the same 586-unit advance as every other decimal
  digit. The source font has no OpenType `tnum` feature; this fixes the actual
  metrics rather than relying on a UI request for monospaced digits.
- Preserves the previous `5`, `Z/z`, `V/v`, `Ы/ы` changes and all other glyphs.

The family name remains distinct from Pixelify Sans as required for this
derivative. The accompanying OFL license and original attribution are unchanged.

Rebuild with fonttools 4.62.1 and either the original Pixelify Sans variable TTF
or the 0.4.7–0.4.10 Moto Link Pixel static TTF:

```text
python scripts/build-readable-font.py source.ttf ios/MotoLink/Fonts/MotoLinkPixel.ttf --source-tree ios/MotoLink --manifest ios/MotoLink/Fonts/coverage.json
python -m unittest discover -s tests -p test_pixel_font.py -v
```

`coverage.json` records source/output SHA-256, all 173 required characters,
581 Unicode mappings and each decimal advance. The build rejects missing
characters across all Swift string literals, including non-UI strings, the full
Russian alphabet and printable ASCII. The standard-library regression suite
checks the shipped TTF directly without requiring fonttools in CI.

FreeType/Pillow visual review used light and dark samples at 15/18/22/32 point
equivalent sizes rendered at 2×, including all Russian letters, numerals,
`0/О/O`, `5/S`, `2/Z`, `V/U`, and the new symbols. UI screenshot validation is
separate; the font itself does not choose Dynamic Type sizes or screen layout.
