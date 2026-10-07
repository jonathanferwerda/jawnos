#!/usr/bin/env python3
"""Render what the watch face will look like, using the glyph tables out of the
generated clock font file (so the data itself gets checked, not just the TTF).

Mimics LVGL's placement: a label aligned TOP_MID at (x, y) with its text
centred, the baseline sitting line_height - base_line below the label's top.

Usage: python3 face_preview.py [out.png]
"""
import re
import sys

from PIL import Image, ImageDraw, ImageFont

try:
    from lv_font_digits import rasterise
except ImportError:                      # when run from another directory
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from lv_font_digits import rasterise

HERE = __file__.rsplit("/", 1)[0]
CLOCK = HERE + "/../fonts/clock_font_54.c"
TTF = ("/home/jawn/jawnos-fw/watch-libs/lvgl/scripts/generators/"
       "built_in_font/Montserrat-Medium.ttf")

W = H = 240
BG = (0, 0, 0)
GREEN = (0, 255, 0)
YELLOW = (0xFF, 0xE0, 0x00)
CYAN = (0x5a, 0xfc, 0xdd)
WHITE = (255, 255, 255)
# line_height / base_line of the montserrat sizes the face uses
LVGL_METRICS = {16: (19, 3), 20: (24, 4), 24: (26, 4), 48: (52, 9)}


def load_clock_font(path):
    src = open(path).read()
    body = re.search(r"glyph_bitmap\[\] = \{(.*?)\};", src, re.S).group(1)
    data = [int(b, 16) for b in re.findall(r"0x([0-9a-f]{2})", body)]
    entries = re.findall(
        r"\{\.bitmap_index = (\d+), \.adv_w = (\d+), \.box_w = (\d+), "
        r"\.box_h = (\d+), \.ofs_x = (-?\d+), \.ofs_y = (-?\d+)\}", src)
    glyphs = [tuple(map(int, e)) for e in entries]
    line_height = int(re.search(r"\.line_height = (\d+)", src).group(1))
    base_line = int(re.search(r"\.base_line = (\d+)", src).group(1))
    return data, glyphs, line_height, base_line


def blend(draw, x, y, colour, alpha):
    if alpha <= 2:
        return
    r = (colour[0] * alpha + BG[0] * (255 - alpha)) // 255
    g = (colour[1] * alpha + BG[1] * (255 - alpha)) // 255
    b = (colour[2] * alpha + BG[2] * (255 - alpha)) // 255
    draw.point((x, y), (r, g, b))


def draw_clock_text(draw, text, x, y, data, glyphs, line_height, base_line):
    order = "0123456789:"
    advances = [glyphs[order.index(c) + 1][1] / 16.0 for c in text]
    pen = x - sum(advances) / 2
    baseline = y + line_height - base_line
    for ch, adv in zip(text, advances):
        bi, _, box_w, box_h, ofs_x, ofs_y = glyphs[order.index(ch) + 1]
        gx = int(round(pen)) + ofs_x
        gy = baseline - ofs_y - box_h
        nibbles = []
        for byte in data[bi:bi + (box_w * box_h + 1) // 2]:
            nibbles += [byte >> 4, byte & 0x0F]
        for row in range(box_h):
            for col in range(box_w):
                blend(draw, gx + col, gy + row, YELLOW, nibbles[row * box_w + col] * 17)
        pen += adv


def draw_lvgl_label(draw, text, x, y, size, colour, align="mid", width=0):
    """x is the label's left edge (align mid/right adjust from there)."""
    line_height, base_line = LVGL_METRICS[size]
    font = ImageFont.truetype(TTF, size)
    if align == "mid":
        x = x + width / 2 - font.getlength(text) / 2
    elif align == "right":
        x = x + width - font.getlength(text)
    baseline = y + line_height - base_line
    pen = x
    for ch in text:
        _, _, _, ofs_y, _, rows = rasterise(font, ch)
        if rows:
            gx = int(round(pen))
            for j, row in enumerate(rows):
                for i, a in enumerate(row):
                    blend(draw, gx + i, baseline - ofs_y - len(rows) + j, colour, a)
        pen += font.getlength(ch)


def face(net_room=False, buttons=False, output="face_preview.png"):
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)

    # status bar: percent, name, volts
    draw_lvgl_label(draw, "78%", 10, 4, 16, GREEN)
    draw_lvgl_label(draw, "jawnbase", 10 + 55, 4, 16, GREEN)
    draw_lvgl_label(draw, "4.12", 195, 4, 16, GREEN, align="right", width=45)

    # clock
    draw_lvgl_label(draw, "Wed Oct 07 2026", 10, 26, 16, YELLOW, width=220)

    data, glyphs, lh, bl = load_clock_font(CLOCK)
    draw_clock_text(draw, "12:34", 120, 44, data, glyphs, lh, bl)

    # seconds and steps share a line
    draw_lvgl_label(draw, "56", -38 + 120 - 40, 112, 24, YELLOW, width=80)
    draw_lvgl_label(draw, "12345", 38 + 120 - 40, 112, 24, CYAN, width=80)

    if net_room:
        draw_lvgl_label(draw, "192.168.1.44", 20, 140, 16, WHITE)
        draw_lvgl_label(draw, "192.168.1.1", 130, 140, 16, WHITE)
        draw_lvgl_label(draw, "192.168.3.1", 20, 160, 16, WHITE)
        draw_lvgl_label(draw, "192.168.3.1", 130, 160, 16, WHITE)

    if buttons:
        for bx, label in ((30, "WI"), (80, "AP"), (210, "BT")):
            draw.rounded_rectangle([bx - 20, 0, bx + 20, 40], 6, fill=(90, 90, 90))
            draw_lvgl_label(draw, label, bx - 20, 10, 16, (0, 0, 0), width=40)

    img.save(output)
    print("wrote", output)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else HERE + "/face_preview.png"
    face(False, False, out)
