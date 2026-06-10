#!/usr/bin/env python3
"""
Generate ModMixer's icons from one vector design — the "#1 bolt-heads" mark:
three faders whose knobs are rotated hex bolt-heads with drilled centres, the
top (winner) knob in FS green.

Two outputs, one geometry:
  * STORE icon  (icon_ModMixer.dds, full colour): dark squircle + green/white bolts.
  * MENU glyph  (gui/menuIcon.dds, white-on-transparent, holes PUNCHED through):
    a simplified, tintable glyph like a native menu icon.

Authored here in code (+ art/icon_master.svg) so the icons are provably ours —
no borrowed pixels. DDS written as uncompressed BGRA (A8R8G8B8), the same
uncompressed form the engine already loads for our icons.
"""
import os, struct, math
from PIL import Image, ImageDraw
import numpy as np

HERE    = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
SRC     = os.path.join(PROJECT, "FS25_ModMixer")
GUI     = os.path.join(SRC, "gui")
PREVIEW = PROJECT  # drop preview PNGs at project root (gitignored _*)

SIZE = 256
SS   = 4                      # supersample factor for anti-aliasing
S    = SIZE * SS

# palette
DARK   = (30, 35, 43, 255)    # #1E232B  tile
TRACK  = (231, 236, 241, 255) # #E7ECF1  fader rails
WHITE  = (237, 239, 242, 255) # #EDEFF2  plain knobs
GREEN  = (141, 198, 63, 255)  # #8DC63F  winner knob (FS green)
HOLE   = (22, 26, 33, 255)    # #161A21  drilled centre (store)
RADIUS = 57                   # squircle corner radius

# geometry (256 space): tracks + hex knobs (cx, cy, kind, rotation deg)
TRACKS = [(55, 88, 201, 88), (55, 132, 201, 132), (55, 176, 201, 176)]
TRACK_W = 13
KNOBS = [(165, 88, "win", 10), (95, 132, "w", -18), (176, 176, "w", 22)]
HEX_R  = 23
HOLE_R = 7


def hexagon(cx, cy, r, rot_deg):
    a0 = math.radians(rot_deg)
    return [(cx + r * math.cos(a0 + i * math.pi / 3),
             cy + r * math.sin(a0 + i * math.pi / 3)) for i in range(6)]


def capsule(d, x1, y1, x2, y2, w, fill):
    d.line([(x1, y1), (x2, y2)], fill=fill, width=w)
    r = w / 2.0
    for (x, y) in ((x1, y1), (x2, y2)):
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def draw_icon(full_color):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = SS

    if full_color:
        d.rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS * k, fill=DARK)

    rail = TRACK if full_color else (255, 255, 255, 255)
    for (x1, y1, x2, y2) in TRACKS:
        capsule(d, x1 * k, y1 * k, x2 * k, y2 * k, TRACK_W * k, rail)

    for (cx, cy, kind, rot) in KNOBS:
        if full_color:
            col = GREEN if kind == "win" else WHITE
        else:
            col = (255, 255, 255, 255)
        d.polygon([(px * k, py * k) for (px, py) in hexagon(cx, cy, HEX_R, rot)], fill=col)
        # drilled centre: dark on the store icon, punched clean through on the glyph
        hb = [(cx - HOLE_R) * k, (cy - HOLE_R) * k, (cx + HOLE_R) * k, (cy + HOLE_R) * k]
        d.ellipse(hb, fill=HOLE if full_color else (0, 0, 0, 0))

    return img.resize((SIZE, SIZE), Image.LANCZOS)


def write_dds(path, img):
    w, h = img.size
    bgra = np.array(img)[:, :, [2, 1, 0, 3]].tobytes()
    header = struct.pack(
        "<7I 11I 8I 5I",
        124, 0x100F, h, w, w * 4, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        32, 0x41, 0, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000,
        0x1000, 0, 0, 0, 0,
    )
    with open(path, "wb") as f:
        f.write(b"DDS " + header + bgra)


store = draw_icon(True)
glyph = draw_icon(False)

write_dds(os.path.join(SRC, "icon_ModMixer.dds"), store)
write_dds(os.path.join(GUI, "menuIcon.dds"), glyph)
store.save(os.path.join(PREVIEW, "_icon_store_preview.png"))

# glyph preview: composite on a menu-grey so the white shapes are visible
bg = Image.new("RGBA", (SIZE, SIZE), (51, 55, 62, 255))
bg.alpha_composite(glyph)
bg.convert("RGB").save(os.path.join(PREVIEW, "_icon_glyph_preview.png"))

print("store icon  ->", os.path.join(SRC, "icon_ModMixer.dds"), store.size)
print("menu glyph  ->", os.path.join(GUI, "menuIcon.dds"), glyph.size)
print("previews    -> _icon_store_preview.png / _icon_glyph_preview.png")
