#!/usr/bin/env python3
"""Build the minimal MotoLink iOS icon from a fixed 64-pixel grid.

The artwork is intentionally code-native: six flat colours, no lettering or
trademark, no baked iOS corner mask, and nearest-neighbour scaling only.
"""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "ios/MotoLink/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

INK = "#101418"
GRAPHITE = "#252B32"
RUBBER = "#05080B"
SCARLET = "#EC454C"
SCARLET_DARK = "#AF232F"
IVORY = "#F3F1E9"


def build() -> Image.Image:
    icon = Image.new("RGB", (64, 64), INK)
    d = ImageDraw.Draw(icon)

    # One strong red field makes the bike legible even at the Home Screen size.
    d.polygon([(8, 39), (13, 31), (19, 25), (38, 22), (49, 28), (55, 39),
               (53, 47), (11, 47)], fill=GRAPHITE)

    # Oversized tires are the visual anchor. They are fully within the mask.
    for center_x in (18, 47):
        d.ellipse((center_x - 11, 33, center_x + 11, 55), fill=RUBBER)
        d.ellipse((center_x - 8, 36, center_x + 8, 52), fill=SCARLET)
        d.ellipse((center_x - 5, 39, center_x + 5, 49), fill=INK)
        d.rectangle((center_x - 2, 42, center_x + 2, 46), fill=IVORY)

    # An intentionally simple motorcycle silhouette: seat, tank, frame and fork.
    d.polygon([(14, 25), (27, 25), (31, 28), (28, 31), (14, 30), (11, 27)],
              fill=GRAPHITE)
    d.rectangle((14, 25, 27, 26), fill=IVORY)
    d.polygon([(27, 25), (31, 20), (40, 20), (47, 27), (43, 32), (32, 32),
               (25, 29)], fill=SCARLET)
    d.rectangle((31, 22, 37, 23), fill=IVORY)
    d.polygon([(43, 28), (49, 30), (51, 35), (46, 38), (42, 33)],
              fill=SCARLET_DARK)
    d.polygon([(21, 32), (31, 37), (43, 31), (46, 35), (34, 42), (29, 41)],
              fill=SCARLET)
    d.polygon([(29, 33), (38, 33), (40, 40), (34, 43), (27, 39)], fill=GRAPHITE)
    d.rectangle((32, 35, 36, 38), fill=IVORY)
    d.rectangle((21, 39, 29, 40), fill=SCARLET)

    # Fork and cockpit use just a few large squares instead of tiny mechanics.
    d.polygon([(43, 30), (46, 30), (50, 42), (47, 42)], fill=SCARLET)
    d.rectangle((43, 23, 45, 30), fill=SCARLET)
    d.rectangle((40, 21, 51, 23), fill=IVORY)
    d.rectangle((49, 20, 53, 22), fill=SCARLET)
    d.rectangle((49, 30, 53, 33), fill=IVORY)

    # The artwork sits optically above centre inside iOS's rounded mask.
    centered = Image.new("RGB", (64, 64), INK)
    centered.paste(icon.crop((0, 5, 64, 64)), (0, 0))
    return centered


if __name__ == "__main__":
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    build().resize((1024, 1024), Image.Resampling.NEAREST).save(TARGET, optimize=True)
    print(TARGET)
