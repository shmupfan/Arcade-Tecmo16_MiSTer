#!/usr/bin/env python3
"""Tecmo 16 reference renderer (PLAN M0.5).

Implements spec sections 5-9 (docs/tecmo16_system_spec.md) from a MAME
oracle frame dump (sim/mame/t16_oracle.lua) plus the region images from
tools/build_regions.py, and reproduces MAME's frame pixel for pixel. It is
the model the M1 video RTL is checked against, written from the spec and
the vendored sources (reference/mame/tecmo16.cpp, tecmo_spr.cpp,
tecmo_mix.cpp).

The renderer works on MAME's full 256 x 256 screen bitmap and crops the
visible lines 16-239 (tecmo16.cpp:681-682) at the end.

Pixel values follow MAME's intermediate bitmaps (spec 8):
  bg  = colour*16 + pen          colour = bgcram & 0x0f  (tecmo16.cpp:163-172)
  fg  = colour*16 + pen          colour = fgcram & 0x1f, bit 8 = blend (149-161)
  tx  = 0x100 + colour*16 + pen  colour = char >> 12     (174-181, 651)
  spr = (pal | attr & 0x3f0)*16 + pen                    (tecmo_spr.cpp:157-172)
and the mixer (tecmo_mix.cpp:70-323) turns them into RGB. Branches where
MAME writes machine().rand() are reported in a mask, not reproduced.

Usage:
  t16_render.py <frame_dir> [--out out.png]
"""
import json
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent.parent
REGIONS = ROOT / "sim" / "build" / "regions"

W = H = 256                  # screen bitmap, tecmo16.cpp:681
VIS_Y0, VIS_Y1 = 16, 240     # visible lines, tecmo16.cpp:682

# mixer configuration, tecmo16.cpp:693-698 and tecmo_mix.h:22-52
SPRPRI_SHIFT, SPRBLN_SHIFT, SPRCOL_SHIFT = 10, 9, 4
BG_BLEND, FG_BLEND, TX_BLEND, SP_BLEND = 0x700, 0x600, 0x500, 0x400
BG_REG, FG_REG, TX_REG, SP_REG = 0x300, 0x200, 0x100, 0x000
SP_BLEND_SRC, FG_BLEND_SRC = 0x800, 0x900
BGPEN, BGPEN_BLEND = 0x300, 0x700
REVSPRITETILE = 3

# sprite chain layout, tecmo_spr.cpp:41-51
LAYOUT = np.array([
    [0, 1, 4, 5, 16, 17, 20, 21],
    [2, 3, 6, 7, 18, 19, 22, 23],
    [8, 9, 12, 13, 24, 25, 28, 29],
    [10, 11, 14, 15, 26, 27, 30, 31],
    [32, 33, 36, 37, 48, 49, 52, 53],
    [34, 35, 38, 39, 50, 51, 54, 55],
    [40, 41, 44, 45, 56, 57, 60, 61],
    [42, 43, 46, 47, 58, 59, 62, 63]])


def _packed_msb(data):
    """gfx_8x8x4_packed_msb: 32 bytes per tile, row-major, high nibble = left pixel."""
    b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 8, 4)
    out = np.empty((b.shape[0], 8, 8), dtype=np.uint8)
    out[:, :, 0::2] = b >> 4
    out[:, :, 1::2] = b & 15
    return out


@lru_cache(maxsize=None)
def fg8(setname):
    """fgtiles region, 8x8x4 packed (tecmo16.cpp:651) -> (n, 8, 8)."""
    return _packed_msb((REGIONS / setname / "fgtiles.bin").read_bytes())


@lru_cache(maxsize=None)
def bg16(setname):
    """bgtiles region, gfx_8x8x4_row_2x2_group_packed_msb (tecmo16.cpp:652):
    16x16 tiles made of four 8x8 packed tiles in row order
    (top-left, top-right, bottom-left, bottom-right) -> (n, 16, 16)."""
    t = _packed_msb((REGIONS / setname / "bgtiles.bin").read_bytes())
    t = t.reshape(-1, 2, 2, 8, 8)
    return t.transpose(0, 1, 3, 2, 4).reshape(-1, 16, 16)


@lru_cache(maxsize=None)
def spr8(setname):
    """sprites region, 8x8x4 packed (tecmo16.cpp:656) -> (n, 8, 8)."""
    return _packed_msb((REGIONS / setname / "sprites.bin").read_bytes())


def words(path):
    return np.frombuffer(Path(path).read_bytes(), dtype=">u2").astype(np.int64)


def palette_rgb(pal_bytes, entries=4096):
    """xBGR_444 (tecmo16.cpp:688): R bits 0-3, G 4-7, B 8-11, pal4bit."""
    w = np.frombuffer(pal_bytes, dtype=">u2")[:entries].astype(np.int64)
    c = np.stack([w & 15, (w >> 4) & 15, (w >> 8) & 15], axis=-1)
    return ((c << 4) | c).astype(np.int64)


def tilemap_coords(n, scroll, dist, size, flip):
    """MAME tilemap scroll (tilemap.cpp effective_rowscroll/colscroll):
    screen coordinate i of an n-wide bitmap samples logical
      (i - dist + scroll)            unflipped
      (n - 1 - i - dist + scroll)    flipped (dist = the flipped delta)
    modulo the tilemap size."""
    i = np.arange(n)
    src = (n - 1 - i) if flip else i
    return (src - dist + scroll) % size


def layer(tiles, codes, colours, cols, rows, tsize, sx, sy, dx, dy, flip, base=0):
    """Draw one tilemap into a 256x256 value bitmap (0 = transparent pen)."""
    codes = codes[:cols * rows] % len(tiles)
    pix = tiles[codes].reshape(rows, cols, tsize, tsize).transpose(0, 2, 1, 3).reshape(rows * tsize, cols * tsize)
    colv = np.repeat(np.repeat(colours[:cols * rows].reshape(rows, cols), tsize, 0), tsize, 1)
    ys = tilemap_coords(H, sy, dy, rows * tsize, flip)
    xs = tilemap_coords(W, sx, dx, cols * tsize, flip)
    p = pix[np.ix_(ys, xs)].astype(np.int64)
    c = colv[np.ix_(ys, xs)].astype(np.int64)
    return np.where(p != 0, base + c * 16 + p, 0)


def draw_sprites(setname, spram, sizey_shift, flip):
    """gaiden_draw_sprites (tecmo_spr.cpp:74-178) into a 256x256 value
    bitmap, clipped to the visible area, later entries drawn on top."""
    tiles = spr8(setname)
    bm = np.zeros((H, W), dtype=np.int64)
    used = 0
    for k in range(256):
        a = spram[k * 8: k * 8 + 8]
        attr = int(a[0])
        if not attr & 4:
            continue
        flipx, flipy = bool(attr & 1), bool(attr & 2)
        colw = int(a[2])
        sizex = 1 << (colw & 3)
        sizey = 1 << ((colw >> sizey_shift) & 3)
        number = int(a[1])
        if sizex >= 2: number &= ~0x01
        if sizey >= 2: number &= ~0x02
        if sizex >= 4: number &= ~0x04
        if sizey >= 4: number &= ~0x08
        if sizex >= 8: number &= ~0x10
        if sizey >= 8: number &= ~0x20
        ypos = int(a[3]) & 0x1ff
        xpos = int(a[4]) & 0x1ff          # xmask 256 for a 256-wide screen
        colour = ((colw >> 4) & 15) | (attr & 0x3f0)
        if xpos >= 256: xpos -= 512
        if ypos >= 256: ypos -= 512
        if flip:
            flipx, flipy = not flipx, not flipy
            xpos = 256 - 8 * sizex - xpos
            ypos = 256 - 8 * sizey - ypos
            if xpos <= -256: xpos += 512
            if ypos <= -256: ypos += 512
        used += 1
        for row in range(sizey):
            for col in range(sizex):
                sx = xpos + 8 * ((sizex - 1 - col) if flipx else col)
                sy = ypos + 8 * ((sizey - 1 - row) if flipy else row)
                t = tiles[(number + LAYOUT[row][col]) % len(tiles)]
                if flipx: t = t[:, ::-1]
                if flipy: t = t[::-1, :]
                x0, y0 = max(sx, 0), max(sy, VIS_Y0)
                x1, y1 = min(sx + 8, W), min(sy + 8, VIS_Y1)
                if x1 <= x0 or y1 <= y0:
                    continue
                sub = t[y0 - sy:y1 - sy, x0 - sx:x1 - sx]
                m = sub != 0
                reg = bm[y0:y1, x0:x1]
                reg[m] = colour * 16 + sub[m].astype(np.int64)
    return bm, used


def mix(bg, fg, tx, sp, pal, rand_fallback=False):
    """tecmo_mix_device::mix_bitmaps (tecmo_mix.cpp:70-323). Returns
    (rgb (H, W, 3), rand mask of pixels where MAME writes machine().rand()).

    rand_fallback=True: the four rand() branches take the branch below them
    instead, which is what the RTL does (research item R6, m1_findings);
    the mask still marks those pixels."""
    sprpri = (sp >> SPRPRI_SHIFT) & 3
    sprbln = (sp >> SPRBLN_SHIFT) & 1
    sprcol = (sp >> SPRCOL_SHIFT) & 15
    spix = (sp & 15) | (sprcol << 4)
    fgbln = (fg >> 8) & 1
    fgp = fg & 0xff
    bgp = bg & 0xff
    txp = tx & 0xff
    spr_on = (spix & 15) != 0
    tx_on = (txp & 15) != 0
    fg_on = (fgp & 15) != 0
    bg_on = (bgp & 15) != 0

    out = np.zeros(bg.shape + (3,), dtype=np.int64)
    rnd = np.zeros(bg.shape, dtype=bool)
    done = np.zeros(bg.shape, dtype=bool)

    def put(cond, colour):
        nonlocal done
        c = cond & ~done
        if isinstance(colour, np.ndarray) and colour.ndim == 3:
            out[c] = colour[c]
        else:
            out[c] = colour
        done |= c

    def pen(idx):
        return pal[idx % 4096]

    def summ(i1, i2):
        return np.minimum(255, pen(i1) + pen(i2))

    def rand(cond):
        nonlocal done
        c = cond & ~done
        rnd[c] = True
        if not rand_fallback:
            done |= c

    bgpen_blend = np.full(bg.shape, BGPEN_BLEND, dtype=np.int64)
    p_behind = spr_on & (sprpri == (0 ^ REVSPRITETILE))
    p_abovebg = spr_on & (sprpri == (1 ^ REVSPRITETILE))
    p_abovefg = spr_on & (sprpri == (2 ^ REVSPRITETILE))
    p_top = spr_on & (sprpri == (3 ^ REVSPRITETILE))
    bl = sprbln == 1

    # sprite behind all (tecmo_mix.cpp:109-145)
    put(p_behind & tx_on, pen(txp + TX_REG))
    rand(p_behind & fg_on & (fgbln == 1))
    put(p_behind & fg_on, pen(fgp + FG_REG))
    put(p_behind & bg_on, pen(bgp + BG_REG))
    rand(p_behind & bl)
    put(p_behind, pen(spix + SP_REG))

    # above bg, behind fg and tx (146-197)
    put(p_abovebg & tx_on, pen(txp + TX_REG))
    put(p_abovebg & fg_on & (fgbln == 1) & bl, summ(bgp + BG_BLEND, spix + SP_BLEND_SRC))
    put(p_abovebg & fg_on & (fgbln == 1), summ(fgp + FG_BLEND_SRC, spix + SP_BLEND))
    put(p_abovebg & fg_on, pen(fgp + FG_REG))
    put(p_abovebg & bl & bg_on, summ(bgp + BG_BLEND, spix + SP_BLEND_SRC))
    put(p_abovebg & bl, summ(bgpen_blend, spix + SP_BLEND_SRC))
    put(p_abovebg, pen(spix + SP_REG))

    # above bg and fg, behind tx (198-243)
    put(p_abovefg & tx_on, pen(txp + TX_REG))
    rand(p_abovefg & bl & fg_on & (fgbln == 1))
    put(p_abovefg & bl & fg_on, summ(fgp + FG_BLEND, spix + SP_BLEND_SRC))
    put(p_abovefg & bl & bg_on, summ(bgp + BG_BLEND, spix + SP_BLEND_SRC))
    put(p_abovefg & bl, summ(bgpen_blend, spix + SP_BLEND_SRC))
    put(p_abovefg, pen(spix + SP_REG))

    # above all (245-285)
    put(p_top & bl & tx_on, summ(txp + TX_BLEND, spix + SP_BLEND_SRC))
    rand(p_top & bl & fg_on & (fgbln == 1))
    put(p_top & bl & fg_on, summ(fgp + FG_BLEND, spix + SP_BLEND_SRC))
    put(p_top & bl & bg_on, summ(bgp + BG_BLEND, spix + SP_BLEND_SRC))
    put(p_top & bl, summ(bgpen_blend, spix + SP_BLEND_SRC))
    put(p_top, pen(spix + SP_REG))

    # no sprite pixel (287-320)
    ns = ~spr_on
    put(ns & tx_on, pen(txp + TX_REG))
    put(ns & fg_on & (fgbln == 1) & bg_on, summ(fgp + FG_BLEND_SRC, bgp + BG_BLEND))
    put(ns & fg_on & (fgbln == 1), summ(fgp + FG_BLEND_SRC, bgpen_blend))
    put(ns & fg_on, pen(fgp + FG_REG))
    put(ns & bg_on, pen(bgp + BG_REG))
    put(ns, pal[BGPEN])
    assert done.all()
    return out.astype(np.uint8), rnd


def layers(frame_dir, regions_set=None, sprites="prev"):
    """Value bitmaps (bg, fg, tx, sp) of one frame dump, full 256x256."""
    d = Path(frame_dir)
    st = json.loads((d / "state.json").read_text())
    setname = regions_set or st["set"]
    machine = st["machine"]
    flip = bool(st["flip_x"])
    cols = 32 if machine == "base" else 64       # tecmo16.cpp:195-196, 219-220, 241-242
    b16 = bg16(setname)
    fgv, fgc = words(d / "fgvram.bin"), words(d / "fgcram.bin")
    bgv, bgc = words(d / "bgvram.bin"), words(d / "bgcram.bin")
    ch = words(d / "charram.bin")
    bg = layer(b16, bgv & 0x1fff, bgc & 0x0f, cols, 32, 16,
               st["bg_scroll_x"], st["bg_scroll_y"], 0, 0, flip)
    fg = layer(b16, fgv & 0x1fff, fgc & 0x1f, cols, 32, 16,
               st["fg_scroll_x"], st["fg_scroll_y"], 0, 0, flip)
    # text layer scroll y: fstarfrc video_start sets -16 until the game
    # writes 0x160006 (tecmo16.cpp:203); every write sets char_y - 16
    # (306); riot adds scrolldy -16 for both orientations (248)
    if machine == "base":
        ty = (st["char_scroll_y"] - 16) if st["char_y_written"] else -16
        tdy = 0
    elif machine == "riot":
        ty = (st["char_scroll_y"] - 16) if st["char_y_written"] else 0
        tdy = -16
    else:
        ty = (st["char_scroll_y"] - 16) if st["char_y_written"] else 0
        tdy = 0
    tx = layer(fg8(setname), ch & 0x0fff, ch >> 12, 64, 32, 8,
               st["char_scroll_x"], ty, 0, tdy, flip, base=0x100)
    spfile = {"prev": "spr_buf_prev.bin", "buf": "spr_buf.bin", "live": "spr_live.bin"}[sprites]
    sp, used = draw_sprites(setname, words(d / spfile), 0 if machine == "riot" else 2, flip)
    return st, bg, fg, tx, sp, used


def render(frame_dir, regions_set=None, sprites="prev", rand_fallback=False):
    """Return (rgb (224, 256, 3), rand mask (224, 256), stats)."""
    d = Path(frame_dir)
    st, bg, fg, tx, sp, used = layers(frame_dir, regions_set, sprites)
    pal = palette_rgb((d / "palette.bin").read_bytes())
    rgb, rnd = mix(bg, fg, tx, sp, pal, rand_fallback)
    return rgb[VIS_Y0:VIS_Y1], rnd[VIS_Y0:VIS_Y1], {"sprites_enabled": used}


def main(argv):
    from PIL import Image
    rgb, rnd, stats = render(argv[0])
    out = argv[argv.index("--out") + 1] if "--out" in argv else "render.png"
    Image.fromarray(rgb, "RGB").save(out)
    print(out, stats, "rand px", int(rnd.sum()))


if __name__ == "__main__":
    main(sys.argv[1:])
