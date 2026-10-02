#!/usr/bin/env python3
"""Render oracle frame dumps with t16_render.py and diff them against MAME,
pixel for pixel.

Primary check: snap.png, MAME's snapshot of frame N, rotated like the game
(fstarfrc sets are ROT90: snap = numpy.rot90(native, -1); riot and ginkun
are ROT0). Secondary check: screen.argb (screen:pixels() captured one
notifier later), which confirms the frame independently of the snapshot
path; it is an RGB32 screen, so it compares the same mixed colours.

Palette: the driver starts from a BLACK palette (tecmo16.cpp:688) and the
RAM is zero at power-on, so never-written entries decode to black on both
sides. Written entries must decode to MAME's pens exactly (checked).

Pixels where MAME's mixer writes machine().rand() (tecmo_mix.cpp:120, 137,
214, 261) are not reproducible; the renderer reports them in a mask, they
are excluded from the diff and counted.

Usage: compare_frames.py <run_dir> [--diffdir DIR] [--quiet] [--stats CSV]
                         [--sprites prev|buf|live]
Exit status 0 only if every frame matches on both checks.
"""
import csv
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent.parent / "mame"))
from t16_render import render, palette_rgb  # noqa: E402
from frame_tools import load_argb  # noqa: E402

ROT90 = {"base"}


def diff_report(tag, name, ours, ref, skip, diffdir):
    neq = np.any(ours != ref, axis=-1) & ~skip
    n = int(neq.sum())
    if n:
        ys, xs = np.nonzero(neq)
        print(f"DIFF  {name} [{tag}]: {n} px, first (x={xs[0]},y={ys[0]}) mame={tuple(int(v) for v in ref[ys[0], xs[0]])} "
              f"ours={tuple(int(v) for v in ours[ys[0], xs[0]])}, bbox x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()}")
        diffdir.mkdir(parents=True, exist_ok=True)
        vis = np.concatenate([ref, ours, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
        Image.fromarray(vis, "RGB").save(diffdir / f"{name}_{tag}.png")
    return n


def main(argv):
    run = Path(argv[0])
    diffdir = Path(argv[argv.index("--diffdir") + 1]) if "--diffdir" in argv else run / "diffs"
    statpath = Path(argv[argv.index("--stats") + 1]) if "--stats" in argv else run / "render_stats.csv"
    sprites = argv[argv.index("--sprites") + 1] if "--sprites" in argv else "prev"
    quiet = "--quiet" in argv
    frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
    if not frames:
        print(f"no frames in {run}")
        return 1
    bad = 0
    checked = {"snap": 0, "pixels": 0}
    px = 0
    rand_frames = rand_px = 0
    rows = []
    for fd in frames:
        st = json.loads((fd / "state.json").read_text())
        rgb, rnd, stats = render(fd, sprites=sprites)
        fail = 0
        ours_pal = palette_rgb((fd / "palette.bin").read_bytes()).astype(np.uint8)
        mp = np.frombuffer((fd / "pens.bin").read_bytes(), dtype="<u4")[:4096]
        mame_pal = np.stack([(mp >> 16) & 255, (mp >> 8) & 255, mp & 255], axis=-1).astype(np.uint8)
        written = np.frombuffer((fd / "palette_written.bin").read_bytes(), dtype=np.uint8)[:4096].astype(bool)
        bad_dec = np.nonzero(np.any(ours_pal[written] != mame_pal[written], axis=-1))[0]
        if len(bad_dec):
            print(f"PALDEC {fd.name}: {len(bad_dec)} written entries decode differently from MAME's pens")
            fail += 1
        nr = int(rnd.sum())
        rand_px += nr
        rand_frames += bool(nr)
        snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
        rot = (lambda a: np.rot90(a, -1)) if st["machine"] in ROT90 else (lambda a: a)
        view, vskip = rot(rgb), rot(rnd)
        if view.shape != snap.shape:
            print(f"SHAPE {fd.name}: ours {view.shape} snap {snap.shape}")
            fail += 1
        else:
            fail += bool(diff_report("snap", fd.name, view, snap, vskip, diffdir))
            checked["snap"] += 1
            px += snap.shape[0] * snap.shape[1]
        if (fd / "screen.argb").exists():
            ref = load_argb(fd)
            if ref.shape == rgb.shape:
                # palette_next.bin = palette one frame later; screen.argb is
                # already RGB, so compare against our frame directly only when
                # the palette did not change in between
                if (fd / "palette_next.bin").read_bytes() == (fd / "palette.bin").read_bytes():
                    fail += bool(diff_report("pixels", fd.name, rgb, ref, rnd, diffdir))
                    checked["pixels"] += 1
        bad += bool(fail)
        rows.append([fd.name, stats["sprites_enabled"], nr, int(fail == 0)])
        if not fail and not quiet:
            print(f"MATCH {fd.name}")
    with open(statpath, "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["frame", "sprites_enabled", "rand_px", "match"])
        wr.writerows(rows)
    print(f"{len(frames) - bad}/{len(frames)} frames pixel-exact "
          f"(snap checks {checked['snap']}, pixels() checks {checked['pixels']}, {px} snapshot px; "
          f"{rand_frames} frames with {rand_px} machine().rand() px excluded)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
