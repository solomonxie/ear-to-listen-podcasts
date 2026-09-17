"""Insets the existing App Icon artwork so it isn't crowding the canvas edges.

Adjusts the icon that's already there — it never draws one. The artwork is hand-designed
and lives in git; a script that regenerates it from code would silently replace it.

Idempotent: it measures where the artwork currently sits and scales it to hit
`TARGET_SIDE_MARGIN`, so running twice does nothing the second time.

    venv/bin/python scripts/pad_app_icon.py [--check]
"""
import sys

import numpy as np
from PIL import Image

ICON = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

# Fraction of the canvas left clear on the tightest axis. iOS masks the icon to a rounded
# rectangle, so artwork running to the edge reads as cramped even before anything clips.
TARGET_SIDE_MARGIN = 0.11

# How far from the backdrop a pixel must be to count as artwork.
INK_THRESHOLD = 90
# Ignore specks: a row/column needs this many ink pixels to bound the artwork.
MIN_RUN = 4


def artwork_bounds(image):
    pixels = np.asarray(image.convert("RGB")).astype(int)
    ink = (255 * 3 - pixels.sum(axis=2)) > INK_THRESHOLD
    rows = np.nonzero(ink.sum(axis=1) >= MIN_RUN)[0]
    cols = np.nonzero(ink.sum(axis=0) >= MIN_RUN)[0]
    if not len(rows) or not len(cols):
        raise SystemExit("No artwork found — is the icon blank?")
    return cols.min(), rows.min(), cols.max(), rows.max()


def backdrop(image):
    """The flat colour behind the artwork, read from the corners."""
    pixels = np.asarray(image.convert("RGB")).astype(int)
    corners = [pixels[0, 0], pixels[0, -1], pixels[-1, 0], pixels[-1, -1]]
    return tuple(int(round(v)) for v in np.median(corners, axis=0))


def report(image, label):
    size = image.width
    x0, y0, x1, y1 = artwork_bounds(image)
    margins = [x0, y0, size - 1 - x1, size - 1 - y1]
    print(f"{label}: artwork {x1 - x0 + 1}x{y1 - y0 + 1}px, "
          f"margins L/T/R/B = {', '.join(f'{m / size * 100:.1f}%' for m in margins)}")
    return min(margins) / size


def main():
    image = Image.open(ICON).convert("RGB")
    size = image.width
    current = report(image, "before")

    if "--check" in sys.argv:
        return

    if current >= TARGET_SIDE_MARGIN - 0.005:
        print("Already clear of the edges — nothing to do.")
        return

    x0, y0, x1, y1 = artwork_bounds(image)
    widest = max(x1 - x0 + 1, y1 - y0 + 1)
    scale = (size * (1 - 2 * TARGET_SIDE_MARGIN)) / widest

    # Crop to the artwork and paste it back centred. The backdrop is flat, so a plain
    # crop-and-paste leaves no seam and no need to mask the artwork's soft edges.
    art = image.crop((x0, y0, x1 + 1, y1 + 1))
    art = art.resize((max(1, round(art.width * scale)), max(1, round(art.height * scale))), Image.LANCZOS)

    canvas = Image.new("RGB", (size, size), backdrop(image))
    canvas.paste(art, ((size - art.width) // 2, (size - art.height) // 2))
    canvas.save(ICON, "PNG")

    report(Image.open(ICON), "after ")


if __name__ == "__main__":
    main()
