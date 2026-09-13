"""Generates the 1024x1024 App Icon PNG for Bring Your Own Podcasts."""
import math
from PIL import Image, ImageDraw

SIZE = 1024
BG_TOP = (32, 24, 58)
BG_BOTTOM = (12, 10, 24)
ACCENT = (255, 138, 61)
ACCENT_DIM = (255, 138, 61, 90)


def make_background():
    img = Image.new("RGB", (SIZE, SIZE))
    px = img.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        r = round(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = round(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = round(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(SIZE):
            px[x, y] = (r, g, b)
    return img


def draw_soundwaves(draw, cx, cy):
    radii = [220, 300, 380]
    for i, r in enumerate(radii):
        alpha = 140 - i * 40
        bbox = [cx - r, cy - r, cx + r, cy + r]
        draw.arc(bbox, start=200, end=340, fill=ACCENT + (alpha,), width=18)


def draw_mic(overlay_draw, cx, cy):
    body_w, body_h = 190, 320
    body_box = [cx - body_w / 2, cy - body_h / 2, cx + body_w / 2, cy + body_h / 2]
    overlay_draw.rounded_rectangle(body_box, radius=body_w / 2, fill=(255, 255, 255, 255))

    stand_r = 230
    stand_box = [cx - stand_r, cy - stand_r + 60, cx + stand_r, cy + stand_r + 60]
    overlay_draw.arc(stand_box, start=25, end=155, fill=(255, 255, 255, 255), width=26)

    overlay_draw.line([cx, cy + stand_r + 60, cx, cy + stand_r + 150], fill=(255, 255, 255, 255), width=26)
    overlay_draw.line([cx - 90, cy + stand_r + 150, cx + 90, cy + stand_r + 150], fill=(255, 255, 255, 255), width=26)


def main():
    img = make_background()

    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)
    cx, cy = SIZE // 2, SIZE // 2 - 40
    draw_soundwaves(odraw, cx, cy)
    draw_mic(odraw, cx, cy)

    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    img.save("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", "PNG")


if __name__ == "__main__":
    main()
