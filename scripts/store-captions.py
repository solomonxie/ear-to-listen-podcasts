"""Captioned App Store shots (1320x2868 JPEG): a headline over each simulator capture.

Usage: venv/bin/python scripts/store-captions.py <shots-dir> <out-dir> <en|zh-Hans>
<shots-dir> holds the ScreenshotDriver captures named after their -screen.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1320, 2868
BG = (24, 24, 28)
CAPTIONS = {
    "en": [
        ("search", "Find the moment\nit was said"),
        ("transcript", "Fix any line,\nright in place"),
        ("welcome", "Your own storage.\nNo catalogue."),
        ("album", "Albums from\nyour own files"),
        ("speaker", "Every speaker,\nacross every show"),
        ("home", "Your library,\nnothing you didn't add"),
    ],
    "zh-Hans": [
        ("search", "说过的哪句话\n都能搜到那一秒"),
        ("transcript", "哪句不对\n就原地改"),
        ("welcome", "你自己的存储\n没有内容库"),
        ("album", "你自己的文件\n整理成专辑"),
        ("speaker", "每位主讲人\n跨节目汇总"),
        ("home", "资料库里\n只有你放进来的"),
    ],
}


def font(lang, size):
    if lang == "zh-Hans":
        return ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", size)
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_name("Bold")
    return f


def compose(shot, caption, lang):
    canvas = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(canvas)
    draw.multiline_text((W / 2, 300), caption, font=font(lang, 104), fill="white",
                        anchor="mm", align="center", spacing=28)
    img = Image.open(shot).convert("RGB")
    width = 1040
    img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius=72, fill=255)
    canvas.paste(img, ((W - width) // 2, 560), mask)
    return canvas


def main():
    src, out, lang = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    for index, (name, caption) in enumerate(CAPTIONS[lang], 1):
        path = os.path.join(out, f"{index:02d}-{name}.jpg")
        compose(os.path.join(src, f"{name}.png"), caption, lang).save(path, quality=85)
        print(path)


if __name__ == "__main__":
    main()
