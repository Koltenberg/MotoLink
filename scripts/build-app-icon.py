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

    # The front wheel is seen at a slight angle. Its narrower, taller profile
    # conveys the turn without making the tiny Home Screen icon busy.
    d.ellipse((7, 35, 29, 55), fill=RUBBER)
    d.ellipse((10, 38, 26, 52), fill=SCARLET)
    d.ellipse((13, 41, 23, 49), fill=INK)
    d.rectangle((16, 43, 20, 46), fill=IVORY)
    d.ellipse((38, 32, 56, 56), fill=RUBBER)
    d.ellipse((41, 35, 53, 53), fill=SCARLET_DARK)
    d.ellipse((42, 36, 50, 52), fill=SCARLET)
    d.ellipse((44, 39, 48, 49), fill=INK)
    d.rectangle((45, 43, 48, 46), fill=IVORY)

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

    # A broad lamp face and offset fork echo that same slight front angle.
    # Keep only large shapes; no tiny mechanical details or decoration.
    d.polygon([(43, 30), (47, 30), (49, 43), (46, 44)], fill=SCARLET)
    d.rectangle((43, 23, 46, 29), fill=SCARLET)
    d.rectangle((40, 21, 50, 23), fill=IVORY)
    d.rectangle((49, 20, 53, 22), fill=SCARLET)
    d.polygon([(47, 27), (53, 28), (54, 33), (49, 35), (46, 32)],
              fill=SCARLET_DARK)
    d.rectangle((49, 29, 53, 32), fill=IVORY)

    # The artwork sits optically above centre inside iOS's rounded mask.
    centered = Image.new("RGB", (64, 64), INK)
    centered.paste(icon.crop((0, 5, 64, 64)), (0, 0))
    return centered


if __name__ == "__main__":
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    build().resize((1024, 1024), Image.Resampling.NEAREST).save(TARGET, optimize=True)
    print(TARGET)
