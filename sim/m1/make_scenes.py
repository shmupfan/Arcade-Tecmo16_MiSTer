#!/usr/bin/env python3
"""M1 synthetic scenes for the t16_video RTL, checked against
t16_render.py (rand_fallback: the RTL's deterministic mixer choice, R6).

Writes <out>/<scene_set>/frames/NNNNNN/ dirs in the oracle dump format
(state.json + RAM images), one scene set per machine and flip setting so
each harness process keeps one machine. Graphics come from the real ROM
regions of fstarfrc, riot and ginkun.

Scenes (per machine x flip):
  random      random palette, tile RAM, scroll (full 16 bits), sprites
              (random enable, size, flips, priority, blend, palette, tile,
              9-bit x/y) and fg blend bits; dense enough that every mixer
              branch is hit, including the four rand() branches
  sizes       every x/y size and flip combination on a grid
  wrap        sprites straddling x 0/255, x 256-511 (negative), y 0/255
              and y 256-511, every size
  ends        tile codes at the region ends (bg 0x1fff, text 0x0fff,
              sprite numbers 0xffc0-0xffff whose cells wrap modulo 32,768)
  scroll      scroll registers at 0, 0x00ff, 0x0100, 0x01ff, 0x0200, 0x03ff,
              0x8000, 0xffff and random, all layers
  load        many sprites crossing one line: 24 of 64x64, 128 and 256 of
              8x8, 128 of 16x16 (within the line budget; the probe beyond it
              is m1/capacity.py)
Usage: make_scenes.py <outdir> [--seed N]
"""
import json
import shutil
import sys
from pathlib import Path

import numpy as np

SETS = {"base": "fstarfrc", "riot": "riot", "ginkun": "ginkun"}


def w16(a):
    return np.asarray(a, dtype=">u2").tobytes()


class Scene:
    def __init__(self, machine, flip, rng):
        self.machine, self.flip, self.rng = machine, flip, rng
        n = 1024 if machine == "base" else 2048
        self.pal = rng.integers(0, 0x1000, 4096)
        self.char = rng.integers(0, 0x10000, 2048)
        self.fgv = rng.integers(0, 0x10000, n)
        self.fgc = rng.integers(0, 0x10000, n)
        self.bgv = rng.integers(0, 0x10000, n)
        self.bgc = rng.integers(0, 0x10000, n)
        self.spr = np.zeros(2048, dtype=np.int64)
        self.regs = {k: int(rng.integers(0, 0x10000)) for k in
                     ("char_scroll_x", "char_scroll_y", "fg_scroll_x", "fg_scroll_y", "bg_scroll_x", "bg_scroll_y")}
        self.char_y_written = bool(rng.integers(0, 2))

    def sprite(self, k, attr, num, colw, y, x):
        self.spr[k * 8:k * 8 + 5] = [attr & 0xFFFF, num & 0xFFFF, colw & 0xFFFF, y & 0xFFFF, x & 0xFFFF]

    def write(self, d, setname, frame):
        fd = d / "frames" / f"{frame:06d}"
        fd.mkdir(parents=True, exist_ok=True)
        st = {"set": setname, "machine": self.machine, "frame": frame, "width": 256, "height": 224,
              "vis_min_y": 16, "htotal": 256, "vtotal": 256, **self.regs,
              "char_y_written": self.char_y_written, "flip_x": 255 if self.flip else 0,
              "flip_y": 255 if self.flip else 0}
        (fd / "state.json").write_text(json.dumps(st))
        (fd / "palette.bin").write_bytes(w16(self.pal))
        (fd / "charram.bin").write_bytes(w16(self.char))
        for name, arr in (("fgvram", self.fgv), ("fgcram", self.fgc), ("bgvram", self.bgv), ("bgcram", self.bgc)):
            (fd / f"{name}.bin").write_bytes(w16(arr))
        (fd / "spr_buf_prev.bin").write_bytes(w16(self.spr))


def rand_attr(rng, enable=True):
    a = int(rng.integers(0, 0x10000))
    return (a | 4) if enable else (a & ~4)


def scenes(machine, flip, rng):
    out = []
    # random
    for _ in range(12):
        s = Scene(machine, flip, rng)
        for k in range(256):
            if rng.random() < 0.6:
                colw = int(rng.integers(0, 0x10000))
                if rng.random() < 0.7:
                    colw &= ~0x0F       # mostly small sprites keeps the line load realistic
                    colw |= int(rng.integers(0, 2)) * 5
                s.sprite(k, rand_attr(rng), int(rng.integers(0, 0x10000)), colw,
                         int(rng.integers(0, 0x200)), int(rng.integers(0, 0x200)))
        out.append(("random", s))
    # sizes x flips on a grid
    for page in range(4):
        s = Scene(machine, flip, rng)
        k = 0
        for sx in range(4):
            for sy in range(4):
                fx, fy = page & 1, page >> 1
                # Riot takes the y size from bits 1-0 as well (t16:337-338)
                colw = (int(rng.integers(0, 16)) << 4) | sx | ((sx if machine == "riot" else sy) << 2)
                s.sprite(k, 4 | fx | (fy << 1) | (int(rng.integers(0, 4)) << 6), int(rng.integers(0, 0x10000)),
                         colw, 16 + 56 * sy, 4 + 62 * sx)
                k += 1
        out.append(("sizes", s))
    # wrap positions
    for xs, ys in ((0x1F0, 0x10), (0xF8, 0x40), (0x1C8, 0xF0), (0x100, 0x1F8), (0xC0, 0x1C4), (0x1FF, 0x1FF)):
        s = Scene(machine, flip, rng)
        for k in range(64):
            sz = k % 16
            colw = (k << 4) & 0xF0 | (sz & 3) | ((sz >> 2) << 2)
            s.sprite(k, 4 | (k & 3) | ((k >> 2) & 3) << 6, int(rng.integers(0, 0x10000)), colw,
                     (ys + 9 * k) & 0x1FF, (xs + 7 * k) & 0x1FF)
        out.append(("wrap", s))
    # region ends
    s = Scene(machine, flip, rng)
    s.fgv[:] = 0x1FFF - (np.arange(len(s.fgv)) % 3)
    s.bgv[:] = 0xFFFF - (np.arange(len(s.bgv)) % 5)
    s.char[:] = (s.char & 0xF000) | 0x0FFF
    for k in range(64):
        s.sprite(k, 4 | (k & 3), 0xFFC0 + k, 0x0F | (k << 4), 16 + 3 * k, 3 * k)
    out.append(("ends", s))
    # scroll extremes
    for v in (0x0000, 0x00FF, 0x0100, 0x01FF, 0x0200, 0x03FF, 0x8000, 0xFFFF):
        s = Scene(machine, flip, rng)
        for kk in s.regs:
            s.regs[kk] = v
        s.char_y_written = True
        out.append(("scroll", s))
    # line load
    for count, colw in ((24, 0x0F), (128, 0x00), (256, 0x00), (128, 0x05)):
        s = Scene(machine, flip, rng)
        for k in range(count):
            cw = colw if machine != "riot" else ((colw & 3) | ((colw & 3) << 2))
            s.sprite(k, 4 | (int(rng.integers(0, 4)) << 6) | (k & 0x20), int(rng.integers(0, 0x10000)),
                     cw | ((k & 15) << 4), 100, (k * 3) & 0x1FF)
        out.append(("load", s))
    return out


def main(argv):
    out = Path(argv[0])
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else 16
    if out.exists():
        shutil.rmtree(out)
    rng = np.random.default_rng(seed)
    n = 0
    for machine, setname in SETS.items():
        for flip in (0, 1):
            d = out / f"{machine}_flip{flip}"
            kinds = {}
            for i, (kind, s) in enumerate(scenes(machine, flip, rng)):
                s.write(d, setname, i + 1)
                kinds[f"{i + 1:06d}"] = kind
                n += 1
            (d / "kinds.json").write_text(json.dumps(kinds))
    print(f"wrote {n} scenes in {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
