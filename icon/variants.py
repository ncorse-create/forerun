#!/usr/bin/env python3
"""Three icon directions for Forerun, rendered together at real home-screen sizes."""
from PIL import Image, ImageDraw, ImageFilter
import os

S = 1024
SS = 4
OUT = os.path.dirname(os.path.abspath(__file__))

PAPER = (251, 247, 240)
INK = (36, 31, 26)
AMBER = (199, 125, 51)


def ground(size, base=PAPER, warm=(246, 238, 226)):
    img = Image.new("RGB", (size, size), base)
    glow = Image.new("RGB", (size, size), base)
    gd = ImageDraw.Draw(glow)
    cx, cy, r = size * 0.34, size * 0.28, size * 0.80
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=warm)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.22))
    return Image.blend(img, glow, 0.55)


def bar(d, x0, y0, x1, y1, fill):
    x0, x1 = min(x0, x1), max(x0, x1)
    y0, y1 = min(y0, y1), max(y0, y1)
    r = min(x1 - x0, y1 - y0) / 2
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=fill)


def dot(d, cx, cy, r, fill):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill)


# ---------------------------------------------------------------- A: the route
def variant_a(img, k):
    """A transit line: stops you pass through, then the moment. Optically centred."""
    d = ImageDraw.Draw(img)
    cx = 0.50 * k
    top, bot = 0.215 * k, 0.815 * k
    bar(d, cx - 0.030 * k, top, cx + 0.030 * k, bot, INK)
    for cy in (0.735, 0.585, 0.435):
        dot(d, cx, cy * k, 0.072 * k, PAPER)
        dot(d, cx, cy * k, 0.045 * k, INK)
    dot(d, cx, 0.255 * k, 0.145 * k, AMBER)


# ------------------------------------------------------------- B: the approach
def variant_b(img, k):
    """Rules that lengthen as the moment approaches, and the moment as an amber disc."""
    d = ImageDraw.Draw(img)
    h = 0.052 * k
    left = 0.215 * k
    for cy, length in ((0.745, 0.245), (0.605, 0.375), (0.465, 0.505)):
        bar(d, left, cy * k - h / 2, left + length * k, cy * k + h / 2, INK)
    dot(d, 0.500 * k, 0.268 * k, 0.132 * k, AMBER)


# ----------------------------------------------------------------- C: the lead
def variant_c(img, k):
    """An amber lead-in that runs up to a solid ink moment. One gesture, two colours."""
    d = ImageDraw.Draw(img)
    cx = 0.50 * k
    w = 0.084 * k
    segs = ((0.800, 0.700), (0.665, 0.565), (0.530, 0.455))
    for y0, y1 in segs:
        bar(d, cx - w / 2, y0 * k, cx + w / 2, y1 * k, AMBER)
    dot(d, cx, 0.310 * k, 0.150 * k, INK)


VARIANTS = {"a": variant_a, "b": variant_b, "c": variant_c}


def render(name, fn):
    img = ground(S).resize((S * SS, S * SS), Image.LANCZOS).convert("RGB")
    fn(img, S * SS)
    img = img.resize((S, S), Image.LANCZOS)
    p = os.path.join(OUT, f"variant-{name}.png")
    img.save(p)
    return p


def sheet():
    sizes = (180, 120, 80, 60, 40)
    pad = 22
    w = pad + sum(s + pad for s in sizes)
    h = pad + len(VARIANTS) * (180 + pad)
    canvas = Image.new("RGB", (w, h), (228, 228, 230))
    for row, name in enumerate(sorted(VARIANTS)):
        src = Image.open(os.path.join(OUT, f"variant-{name}.png"))
        x = pad
        y = pad + row * (180 + pad)
        for s in sizes:
            th = src.resize((s, s), Image.LANCZOS)
            mask = Image.new("L", (s, s), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.225, fill=255)
            canvas.paste(th, (x, y + (180 - s) // 2), mask)
            x += s + pad
    canvas.save(os.path.join(OUT, "variants-sheet.png"))


if __name__ == "__main__":
    for n, f in VARIANTS.items():
        render(n, f)
    sheet()
    print("wrote variant-a/b/c.png and variants-sheet.png")
