#!/usr/bin/env python3
"""Forerun app icon generator.

Concept: the run-up. An amber rail is the lead time; ink ticks are the prep steps, each one
longer than the last as the moment approaches; the solid disc at the top is the event itself.
Warm editorial palette, no gloss, no gradient tricks beyond a faint paper warmth.
"""
from PIL import Image, ImageDraw, ImageFilter
import os

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))

PAPER = (251, 247, 240)
INK = (36, 31, 26)
AMBER = (199, 125, 51)
HAIRLINE = (232, 224, 213)


def paper_ground(size, base=PAPER, warm=(246, 238, 226)):
    """Flat paper with a faint off-centre warmth. Subtle enough to survive downscaling."""
    img = Image.new("RGB", (size, size), base)
    glow = Image.new("RGB", (size, size), base)
    gd = ImageDraw.Draw(glow)
    cx, cy, r = size * 0.34, size * 0.30, size * 0.78
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=warm)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.22))
    return Image.blend(img, glow, 0.55)


def rounded_bar(d, x0, y0, x1, y1, fill):
    r = min(abs(x1 - x0), abs(y1 - y0)) / 2
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=fill)


def draw_mark(img, rail_color, tick_color, disc_color, scale=1.0):
    """The mark itself, drawn supersampled by `scale` for clean edges."""
    d = ImageDraw.Draw(img)
    S_ = S * scale

    rail_w = 0.052 * S_
    rail_x = 0.355 * S_
    rail_top = 0.175 * S_
    rail_bot = 0.845 * S_
    rounded_bar(d, rail_x - rail_w / 2, rail_top, rail_x + rail_w / 2, rail_bot, rail_color)

    # Prep steps: each tick reaches further as the event gets closer.
    tick_h = 0.040 * S_
    ticks = [(0.760, 0.150), (0.630, 0.225), (0.500, 0.300)]
    for cy_frac, length_frac in ticks:
        cy = cy_frac * S_
        x0 = rail_x - rail_w * 0.15
        x1 = x0 + length_frac * S_
        rounded_bar(d, x0, cy - tick_h / 2, x1, cy + tick_h / 2, tick_color)

    # The event.
    disc_r = 0.132 * S_
    disc_cy = 0.300 * S_
    d.ellipse([rail_x - disc_r, disc_cy - disc_r, rail_x + disc_r, disc_cy + disc_r],
              fill=disc_color)
    return img


def render(bg, rail, tick, disc, path, transparent=False):
    SS = 4  # supersample
    if transparent:
        img = Image.new("RGBA", (S * SS, S * SS), (0, 0, 0, 0))
    else:
        img = bg.resize((S * SS, S * SS), Image.LANCZOS).convert("RGBA")
    draw_mark(img, rail, tick, disc, scale=SS)
    img = img.resize((S, S), Image.LANCZOS)
    if transparent:
        img.save(path)
    else:
        img.convert("RGB").save(path)
    return path


if __name__ == "__main__":
    light_bg = paper_ground(S)
    render(light_bg, AMBER, INK, INK, os.path.join(OUT, "icon-light.png"))

    # Dark: ink ground, the rail keeps the amber so the app is recognisable in either mode.
    dark_bg = paper_ground(S, base=(26, 23, 20), warm=(44, 38, 32))
    render(dark_bg, AMBER, (236, 229, 219), (236, 229, 219),
           os.path.join(OUT, "icon-dark.png"))

    # Tinted: iOS supplies the colour, so this is a greyscale-on-transparent mask.
    render(None, (255, 255, 255, 255), (188, 188, 188, 255), (255, 255, 255, 255),
           os.path.join(OUT, "icon-tinted.png"), transparent=True)

    # Contact sheet at real home-screen sizes so the mark can be judged small.
    sheet = Image.new("RGB", (760, 220), (240, 240, 240))
    x = 20
    for px in (180, 120, 80, 60, 40, 29):
        thumb = Image.open(os.path.join(OUT, "icon-light.png")).resize((px, px), Image.LANCZOS)
        mask = Image.new("L", (px, px), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, px - 1, px - 1], radius=px * 0.225, fill=255)
        sheet.paste(thumb, (x, 20), mask)
        dark = Image.open(os.path.join(OUT, "icon-dark.png")).resize((px, px), Image.LANCZOS)
        sheet.paste(dark, (x, 130), mask.resize((px, px)))
        x += px + 20
    sheet.save(os.path.join(OUT, "contact-sheet.png"))
    print("wrote icon-light.png, icon-dark.png, icon-tinted.png, contact-sheet.png")
