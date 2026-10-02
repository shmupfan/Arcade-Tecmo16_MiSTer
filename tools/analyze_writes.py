#!/usr/bin/env python3
"""Summarise oracle write logs and per-frame video use for the M0 findings.

For each run directory (sim/mame/out/<run>):
  - video register writes (0x160000-0x16001f): beam lines, how many land in
    the visible area (lines 16-239), frames whose visible-area writes change
    a value, writes to registers MAME does not map
  - IRQ acknowledge writes (0x150031 / 0x150021) per frame, flip writes,
    sound latch writes, ROM-space writes, extra RAM, video register reads
  - per-class RAM write timing (palette, sprite, tile RAM): share of writes
    in the visible area
  - per dumped frame (spr_buf_prev.bin = the list MAME drew): enabled
    sprites, sprites and 8-pixel sprite columns per visible line, sprite
    sizes, blend bits in use (sprite attr bit 5, fg colour bit 4), mixer
    branches that blend, tile codes past the end of a region

Usage: tools/analyze_writes.py <run_dir> [<run_dir> ...]
"""
import csv
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sim" / "oracle"))
from t16_render import layers, words, VIS_Y0, VIS_Y1, SPRBLN_SHIFT  # noqa: E402

VREGS = {"scroll_char_x", "scroll_char_y", "fg_scroll_x", "fg_scroll_y", "bg_scroll_x", "bg_scroll_y"}


def sprite_lines(spram, sizey_shift):
    """Per visible line: enabled sprites crossing it and 8-px columns."""
    nspr = np.zeros(256, dtype=int)
    ncol = np.zeros(256, dtype=int)
    sizes = Counter()
    for k in range(256):
        a = spram[k * 8:k * 8 + 8]
        if not a[0] & 4:
            continue
        sx = 1 << (int(a[2]) & 3)
        sy = 1 << ((int(a[2]) >> sizey_shift) & 3)
        sizes[(sx * 8, sy * 8)] += 1
        y = int(a[3]) & 0x1ff
        if y >= 256:
            y -= 512
        for line in range(max(y, 0), min(y + 8 * sy, 256)):
            nspr[line] += 1
            ncol[line] += sx
    return nspr[VIS_Y0:VIS_Y1], ncol[VIS_Y0:VIS_Y1], sizes


def analyze(run):
    out = []
    p = lambda s="": out.append(s)
    p(f"### {run.name}")
    summ = (run / "summary.txt").read_text().splitlines()
    p("  " + summ[0] + "; " + summ[1])
    hits = {l.split()[1]: int(l.split()[3]) for l in summ if l.startswith("tap ")}

    # register writes
    wr = list(csv.DictReader(open(run / "writes.csv")))
    vr = [w for w in wr if w["class"] in VREGS]
    other_v = Counter(w["class"] for w in wr if w["class"].startswith("vreg_"))
    vis = [w for w in vr if w["visible"] == "1"]
    lines = Counter(int(w["line"]) for w in vr)
    p(f"  video register writes {len(vr)}, in visible area {len(vis)}; top lines {lines.most_common(6)}")
    if other_v:
        p(f"  writes to unmapped video registers: {dict(other_v)}")
    # does a visible-area write change the value MAME latches at vblank?
    last = {}
    changed_vis = Counter()
    for w in vr:
        key = w["class"]
        val = int(w["data"], 16)
        if w["visible"] == "1" and last.get(key) is not None and last[key] != val:
            changed_vis[key] += 1
        last[key] = val
    p(f"  visible-area writes that change a register value: {dict(changed_vis) or 'none'}")
    for cls in ("flip", "soundlatch", "irq_150031", "irq_150021", "romw", "sys_other"):
        n = [w for w in wr if w["class"] == cls]
        if n:
            vals = Counter(w["data"] for w in n).most_common(4)
            p(f"  {cls}: {len(n)} writes, values {vals}, lines {Counter(int(w['line']) for w in n).most_common(3)}")
    p(f"  vreg reads {hits.get('vreg_read', 0)}, extra124 writes {hits.get('extra124', 0)}")

    # per-frame IRQ acknowledge counts
    fr = list(csv.DictReader(open(run / "frames.csv")))
    p(f"  irq_150031 writes per frame {Counter(int(r['irq31']) for r in fr).most_common(6)}")
    p(f"  irq_150021 writes per frame {Counter(int(r['irq21']) for r in fr).most_common(6)}")

    # heavy RAM write classes
    hs = defaultdict(lambda: [0, 0])
    for r in csv.DictReader(open(run / "heavy_summary.csv")):
        hs[r["class"]][0] += int(r["count"])
        hs[r["class"]][1] += int(r["visible_count"])
    p("  RAM writes (total / in visible area): " +
      ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(hs.items())))

    # dumped frames
    frames = sorted(d for d in (run / "frames").iterdir() if d.is_dir())
    max_spr = max_line_spr = max_line_col = 0
    sizes = Counter()
    blend_spr_frames = blend_fg_frames = 0
    mix_cases = Counter()
    for fd in frames:
        st = json.loads((fd / "state.json").read_text())
        machine = st["machine"]
        spram = words(fd / "spr_buf_prev.bin")
        enabled = sum(1 for k in range(256) if spram[k * 8] & 4)
        max_spr = max(max_spr, enabled)
        ns, nc, sz = sprite_lines(spram, 0 if machine == "riot" else 2)
        max_line_spr = max(max_line_spr, int(ns.max()))
        max_line_col = max(max_line_col, int(nc.max()))
        sizes.update(sz)
        _, bg, fg, tx, sp, _ = layers(fd)
        v = slice(VIS_Y0, VIS_Y1)
        bg, fg, tx, sp = bg[v], fg[v], tx[v], sp[v]
        spr_on = (sp & 15) != 0
        sbl = spr_on & (((sp >> SPRBLN_SHIFT) & 1) == 1)
        fbl = ((fg & 15) != 0) & (((fg >> 8) & 1) == 1)
        blend_spr_frames += bool(sbl.any())
        blend_fg_frames += bool(fbl.any())
        pri = (sp >> 10) & 3
        for pr in range(4):
            m = spr_on & (pri == pr)
            if m.any():
                mix_cases[f"spr_pri{pr}"] += int(m.sum())
        if fbl.any():
            mix_cases["fg_blend_px"] += int(fbl.sum())
        if sbl.any():
            mix_cases["spr_blend_px"] += int(sbl.sum())
    p(f"  dumped frames {len(frames)}: max enabled sprites {max_spr}, max sprites on one line {max_line_spr}, "
      f"max 8-px sprite columns on one line {max_line_col}")
    p(f"  sprite sizes used {dict(sizes.most_common(8))}")
    p(f"  frames with blended sprite pixels {blend_spr_frames}, with blended fg pixels {blend_fg_frames}")
    p(f"  visible pixels by case (all frames): {dict(mix_cases)}")
    return "\n".join(out)


def main(argv):
    for r in argv:
        print(analyze(Path(r)))
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
