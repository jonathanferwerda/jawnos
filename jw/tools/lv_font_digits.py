#!/usr/bin/env python3
"""Generate the watch face's clock font as an LVGL 9 font.

The clock only ever shows digits and a colon, so a full font is a waste of
flash: this rasterises just 0-9 and ':' from the Montserrat-Medium that ships
with LVGL and emits the glyph tables lv_font_fmt_txt expects.

The layout conventions were read off lv_font_montserrat_48.c, which was made by
lv_font_conv from this very TTF:
  * adv_w is the advance in 1/16 px
  * a glyph's bitmap is the ink box, ofs_x is the ink's left bearing
  * ofs_y is the distance from the ink's bottom up to the baseline
  * 4bpp rows are NOT padded: pixels run continuously, high nibble first
  * line_height/base_line are the max ink ascent and descent of the whole font

Usage:
  python3 lv_font_digits.py --size 54 --out ../clock_font_54.c
  python3 lv_font_digits.py --size 48 --check     # compare against the 48px font
"""
import argparse
import re

from PIL import ImageFont

HERE = __file__.rsplit("/", 1)[0]
TTF = ("/home/jawn/jawnos-fw/watch-libs/lvgl/scripts/generators/"
       "built_in_font/Montserrat-Medium.ttf")
REF48 = "/home/jawn/jawnos-fw/watch-libs/lvgl/src/font/lv_font_montserrat_48.c"
# where this LVGL declares the structs the initialisers have to follow
FONT_H = "/home/jawn/jawnos-fw/watch-libs/lvgl/include/lvgl/font/lv_font.h"
FMT_H = "/home/jawn/jawnos-fw/watch-libs/lvgl/include/lvgl/font/lv_font_fmt_txt.h"
GLYPHS = "0123456789:"
ASCII = [chr(c) for c in range(32, 127)]

# what we want the public lv_font_t to say; anything else keeps its zero value
FONT_VALUES = [
    ("dsc", "&font_dsc"),
    ("fallback", "NULL"),
    ("user_data", "NULL"),
    ("get_glyph_dsc", "lv_font_get_glyph_dsc_fmt_txt"),
    ("get_glyph_bitmap", "lv_font_get_bitmap_fmt_txt"),
    ("line_height", "{line_height}"),
    ("base_line", "{base_line}"),
    ("subpx", "LV_FONT_SUBPX_NONE"),
    ("underline_position", "{underline_position}"),
    ("underline_thickness", "{underline_thickness}"),
]

# the dsc struct, likewise, in the order the header declares it
DSC_VALUES = [
    ("glyph_bitmap", "glyph_bitmap"),
    ("glyph_dsc", "glyph_dsc"),
    ("cmaps", "cmaps"),
    ("kern_dsc", "NULL"),
    ("kern_scale", "0"),
    ("cmap_num", "1"),
    ("bpp", "4"),
    ("kern_classes", "0"),
    ("bitmap_format", "0"),
]


def struct_field_order(struct_name, path):
    """Field names of an lvgl struct, in declaration order.

    The initialisers have to be written in this order: the file is #included
    into the sketch, so it is compiled as C++ where out-of-order designated
    initialisers are an error (the font files LVGL ships are C, where it is not).
    """
    src = open(path).read()
    body = None
    m = re.search(r"struct\s+" + re.escape(struct_name) + r"\s*\{(.*?)\n\};", src, re.S)
    if m:
        body = m.group(1)
    else:
        m = re.search(r"typedef\s+struct\s*\{(.*?)\n\}\s*" + re.escape(struct_name) + r"\s*;",
                      src, re.S)
        if m:
            body = m.group(1)
    if body is None:
        raise SystemExit(f"could not find struct {struct_name} in {path}")
    found = []
    for name in [n for n, _ in FONT_VALUES] + [n for n, _ in DSC_VALUES]:
        # ends in ';' for a plain field, ')' for a function pointer
        m = re.search(r"\b" + re.escape(name) + r"\s*(?::\s*\d+)?\s*[;)]", body)
        if m:
            found.append((m.start(), name))
    return [n for _, n in sorted(found)]


def rasterise(font, ch):
    """Return (box_w, box_h, ofs_x, ofs_y, adv_w, alpha_rows) for one glyph."""
    mask, off = font.getmask2(ch, mode="L", anchor="ls")
    ink = mask.getbbox()
    if ink is None:                      # blank glyph, e.g. the space
        return 0, 0, 0, 0, round(font.getlength(ch) * 16), []
    left, top, right, bottom = ink
    box_w, box_h = right - left, bottom - top
    ofs_x = off[0] + left
    ofs_y = -(off[1] + bottom)
    adv_w = int(font.getlength(ch) * 16 + 0.5)
    rows = []
    for y in range(top, bottom):
        row = []
        for x in range(left, right):
            row.append(mask.getpixel((x, y)))
        rows.append(row)
    return box_w, box_h, ofs_x, ofs_y, adv_w, rows


def pack_4bpp(box_w, box_h, rows):
    """2 pixels per byte, high nibble first, no padding between rows."""
    out, nibbles = [], []
    for row in rows:
        for a in row:
            nibbles.append((a + 8) // 17)     # 0..255 -> 0..15
    for i in range(0, len(nibbles), 2):
        hi = nibbles[i]
        lo = nibbles[i + 1] if i + 1 < len(nibbles) else 0
        out.append((hi << 4) | lo)
    return out


def font_metrics(size):
    """Line metrics for Montserrat at `size`.

    lv_font_conv derives these from the whole glyph set it is given, and the
    shipped 48 px font (which is this TTF) reports line_height 52, base_line 9.
    Ours only holds digits, so take those proportions and scale them instead of
    measuring our own subset, which would give a much shorter line.
    """
    ascent = round(43 * size / 48)
    descent = round(9 * size / 48)
    return ascent, descent


def reference48():
    src = open(REF48).read()
    gds = [tuple(map(int, g)) for g in re.findall(
        r"\{\.bitmap_index = (\d+),\s*\.adv_w = (\d+),\s*\.box_w = (\d+),"
        r"\s*\.box_h = (\d+),\s*\.ofs_x = (-?\d+),\s*\.ofs_y = (-?\d+)\}", src)]
    # digit and colon glyph ids: ascii glyphs start at id 1 for U+0020
    return {ch: gds[ord(ch) - 0x20 + 1] for ch in GLYPHS}


def do_check():
    font = ImageFont.truetype(TTF, 48)
    ref = reference48()
    ok = True
    for ch in GLYPHS:
        box_w, box_h, ofs_x, ofs_y, adv_w, _ = rasterise(font, ch)
        r_bi, r_adv, r_bw, r_bh, r_ox, r_oy = ref[ch]
        mine = (adv_w, box_w, box_h, ofs_x, ofs_y)
        theirs = (r_adv, r_bw, r_bh, r_ox, r_oy)
        flag = "ok " if mine == theirs else "DIFF"
        if mine != theirs:
            ok = False
        print(f"{flag} {ch!r} mine adv/box/ofs={mine} ref={theirs}")
    asc, desc = font_metrics(48)
    print(f"line_height {asc + desc} (ref 52), base_line {desc} (ref 9)")
    print("check passed" if ok and (asc + desc) == 52 and desc == 9 else "check FAILED")


def generate(size, out_path, symbol):
    font = ImageFont.truetype(TTF, size)
    ascent, descent = font_metrics(size)
    line_height = ascent + descent

    # FORMAT0_TINY maps codepoints straight onto glyph ids, so the glyphs have
    # to be one contiguous ascending run
    codes = [ord(c) for c in GLYPHS]
    if codes != list(range(codes[0], codes[0] + len(codes))):
        raise SystemExit(f"glyphs must be contiguous and ascending: {GLYPHS!r}")

    bitmaps, descs = [], []
    index = 0
    for ch in GLYPHS:
        box_w, box_h, ofs_x, ofs_y, adv_w, rows = rasterise(font, ch)
        data = pack_4bpp(box_w, box_h, rows)
        descs.append((index, adv_w, box_w, box_h, ofs_x, ofs_y))
        bitmaps.append((ch, data))
        index += len(data)

    with open(out_path, "w") as fh:
        fh.write(f"""/*******************************************************************************
 * Size: {size} px
 * Bpp: 4
 * Clock digits generated from Montserrat-Medium.ttf by tools/lv_font_digits.py
 ******************************************************************************/

// included from the sketch, where LVGL is already on the include path
#include "lvgl.h"

#ifndef {symbol.upper()}
#define {symbol.upper()} 1
#endif

#if {symbol.upper()}

/*-----------------
 *    BITMAPS
 *----------------*/

static LV_ATTRIBUTE_LARGE_CONST const uint8_t glyph_bitmap[] = {{
""")
        for ch, data in bitmaps:
            if not data:
                continue
            fh.write(f'    /* "{ch}" */\n')
            for i in range(0, len(data), 12):
                row = ", ".join(f"0x{b:02x}" for b in data[i:i + 12])
                fh.write(f"    {row},\n")
        fh.write("""};

/*Store the glyph descriptions*/
static const lv_font_fmt_txt_glyph_dsc_t glyph_dsc[] = {
    {.bitmap_index = 0, .adv_w = 0, .box_w = 0, .box_h = 0, .ofs_x = 0, .ofs_y = 0},/*(ID:0)*/
""")
        for n, (bi, aw, bw, bh, ox, oy) in enumerate(descs, start=1):
            fh.write(f"    {{.bitmap_index = {bi}, .adv_w = {aw}, .box_w = {bw}, "
                     f".box_h = {bh}, .ofs_x = {ox}, .ofs_y = {oy}}},/*(ID:{n})*/\n")
        fh.write(f"""}};

/*Store the cmap - does not ensure the glyph will be searched.*/
static const lv_font_fmt_txt_cmap_t cmaps[] = {{
    /* 0-9 and the colon are one contiguous range, which is exactly what
     * FORMAT0 is for: glyph id = codepoint - range_start + glyph_id_start.
     * A sparse map would need unicode_list/list_length, and with a length of
     * zero nothing is found and every digit comes out as a missing-glyph box. */
    {{
        .range_start = {ord(GLYPHS[0])}, .range_length = {len(GLYPHS)}, .glyph_id_start = 1,
        .unicode_list = NULL, .glyph_id_ofs_list = NULL, .list_length = 0,
        .type = LV_FONT_FMT_TXT_CMAP_FORMAT0_TINY
    }}
}};

static const lv_font_fmt_txt_dsc_t font_dsc = {{
""")
        values = {"glyph_bitmap": "glyph_bitmap", "glyph_dsc": "glyph_dsc",
                  "cmaps": "cmaps", "kern_dsc": "NULL", "kern_scale": "0",
                  "cmap_num": "1", "bpp": "4", "kern_classes": "0",
                  "bitmap_format": "0"}
        for name in struct_field_order("lv_font_fmt_txt_dsc_t", FMT_H):
            if name in values:
                fh.write(f"    .{name} = {values[name]},\n")
        fh.write(f"""}};

/*-----------------
 *  PUBLIC FONT
 *----------------*/

const lv_font_t {symbol} = {{
""")
        values = dict(FONT_VALUES)
        values["dsc"] = "&font_dsc"
        values["line_height"] = str(line_height)
        values["base_line"] = str(descent)
        values["underline_position"] = str(-(size // 12))
        values["underline_thickness"] = str(max(1, size // 16))
        for name in struct_field_order("_lv_font_t", FONT_H):
            if name in values:
                fh.write(f"    .{name} = {values[name]},\n")
        fh.write(f"""}};

#endif /*#if {symbol.upper()}*/
""")
    print(f"wrote {out_path}: {len(GLYPHS)} glyphs, {index} bitmap bytes, "
          f"line_height {line_height}, base_line {descent}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=54)
    ap.add_argument("--out", default="clock_font.c")
    ap.add_argument("--symbol", default="clock_font")
    ap.add_argument("--check", action="store_true",
                    help="compare the conventions against lv_font_montserrat_48.c")
    args = ap.parse_args()
    if args.check:
        do_check()
        return
    generate(args.size, args.out, args.symbol)


if __name__ == "__main__":
    main()
