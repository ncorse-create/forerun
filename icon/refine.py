#!/usr/bin/env python3
"""Refinement of direction B: prep steps reaching further as the moment approaches."""
from PIL import Image, ImageDraw, ImageFilter
import os

S, SS = 1024, 4
OUT = os.path.dirname(os.path.abspath(__file__))
PAPER, INK, AMBER = (251, 247, 240), (36, 31, 26), (199, 125, 51)


def ground(size, base=PAPER, warm=(246, 238, 226)):
    img = Image.new("RGB", (size, size), base)
    glow = Image.new("RGB", (size, size), base)
    d = ImageDraw.Draw(glow)
    cx, cy, r = size * 0.62, size * 0.26, size * 0.80
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=warm)
    return Image.blend(img, glow.filter(ImageFilter.GaussianBlur(size * 0.22)), 0.55)


def bar(d, x0, y0, x1, y1, fill):
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    d.rounded_rectangle([x0, y0, x1, y1], radius=min(x1 - x0, y1 - y0) / 2, fill=fill)


# Each step reaches further than the last; the amber disc is the moment they arrive at.
STEPS = ((0.735, 0.205), (0.595, 0.320), (0.455, 0.435))
LEFT, H = 0.185, 0.053
DISC = (0.700, 0.268, 0.132)


def mark(img, k, bar_c, disc_c):
    d = ImageDraw.Draw(img)
    for cy, length in STEPS:
        bar(d, LEFT * k, cy * k - H * k / 2, (LEFT + length) * k, cy * k + H * k / 2, bar_c)
    cx, cy, r = DISC
    d.ellipse([(cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k], fill=disc_c)


def render(name, bar_c, disc_c, bg=None):
    img = (bg or ground(S)).resize((S * SS, S * SS), Image.LANCZOS).convert("RGB")
    mark(img, S * SS, bar_c, disc_c)
    img = img.resize((S, S), Image.LANCZOS)
    img.save(os.path.join(OUT, f"{name}.png"))


def sheet(names, out):
    sizes = (180, 120, 80, 60, 40)
    pad = 22
    w = pad + sum(s + pad for s in sizes)
    canvas = Image.new("RGB", (w, pad + len(names) * (180 + pad)), (228, 228, 230))
    for row, n in enumerate(names):
        src = Image.open(os.path.join(OUT, f"{n}.png"))
        x, y = pad, pad + row * (180 + pad)
        for s in sizes:
            mask = Image.new("L", (s, s), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.225, fill=255)
            canvas.paste(src.resize((s, s), Image.LANCZOS), (x, y + (180 - s) // 2), mask)
            x += s + pad
    canvas.save(os.path.join(OUT, out))


if __name__ == "__main__":
    render("b2-ink-steps", INK, AMBER)
    render("b3-amber-steps", AMBER, INK)
    render("b4-dark", (236, 229, 219), AMBER,
           bg=ground(S, base=(26, 23, 20), warm=(46, 39, 33)))
    sheet(["b2-ink-steps", "b3-amber-steps", "b4-dark"], "refine-sheet.png")
    print("ok")
