#!/usr/bin/env python3
"""Final Forerun app icon: light, dark and tinted, written straight into the asset catalog.

The mark: three prep steps, each reaching further than the last as the moment approaches, and
the moment itself as a solid amber disc. Paper ground, ink steps. No gloss, no bevel.
"""
from PIL import Image, ImageDraw, ImageFilter
import json
import os

S, SS = 1024, 4
HERE = os.path.dirname(os.path.abspath(__file__))
APPICON = os.path.abspath(os.path.join(
    HERE, "..", "Forerun", "Resources", "Assets.xcassets", "AppIcon.appiconset"))

PAPER, INK, AMBER = (251, 247, 240), (36, 31, 26), (199, 125, 51)
DARK_GROUND, DARK_STEP = (26, 23, 20), (236, 229, 219)

STEPS = ((0.735, 0.205), (0.595, 0.320), (0.455, 0.435))
LEFT, H = 0.185, 0.053
DISC = (0.700, 0.268, 0.132)


def ground(base, warm):
    img = Image.new("RGB", (S, S), base)
    glow = Image.new("RGB", (S, S), base)
    d = ImageDraw.Draw(glow)
    cx, cy, r = S * 0.62, S * 0.26, S * 0.80
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=warm)
    return Image.blend(img, glow.filter(ImageFilter.GaussianBlur(S * 0.22)), 0.55)


def mark(img, k, bar_c, disc_c):
    d = ImageDraw.Draw(img)
    for cy, length in STEPS:
        x0, x1 = LEFT * k, (LEFT + length) * k
        y0, y1 = (cy - H / 2) * k, (cy + H / 2) * k
        d.rounded_rectangle([x0, y0, x1, y1], radius=(y1 - y0) / 2, fill=bar_c)
    cx, cy, r = DISC
    d.ellipse([(cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k], fill=disc_c)


def render(path, bar_c, disc_c, bg=None):
    if bg is None:
        img = Image.new("RGBA", (S * SS, S * SS), (0, 0, 0, 0))
        mark(img, S * SS, bar_c, disc_c)
        img.resize((S, S), Image.LANCZOS).save(path)
    else:
        img = bg.resize((S * SS, S * SS), Image.LANCZOS).convert("RGB")
        mark(img, S * SS, bar_c, disc_c)
        img.resize((S, S), Image.LANCZOS).save(path)
    return os.path.basename(path)


CONTENTS = {
    "images": [
        {"filename": "icon-light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "icon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
         "filename": "icon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ],
    "info": {"author": "xcode", "version": 1},
}

if __name__ == "__main__":
    os.makedirs(APPICON, exist_ok=True)
    render(os.path.join(APPICON, "icon-light.png"), INK, AMBER,
           bg=ground(PAPER, (246, 238, 226)))
    render(os.path.join(APPICON, "icon-dark.png"), DARK_STEP, AMBER,
           bg=ground(DARK_GROUND, (46, 39, 33)))
    # Tinted: iOS supplies the colour and uses luminance, so this is a greyscale mask on a
    # dark ground. The disc stays brightest so the moment still reads as the focal point.
    render(os.path.join(APPICON, "icon-tinted.png"), (150, 150, 150), (255, 255, 255),
           bg=ground((20, 20, 20), (38, 38, 38)))
    with open(os.path.join(APPICON, "Contents.json"), "w") as f:
        json.dump(CONTENTS, f, indent=2)
    print("wrote", APPICON)
