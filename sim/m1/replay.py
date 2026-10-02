#!/usr/bin/env python3
"""M1 video parity: replay oracle frame dumps through the t16_video RTL
(Verilator harness sim/m1/tb_video.cpp) and compare every frame.

References per frame:
  - MAME's snapshot (snap.png, rotated like the game: Final Star Force sets
    are ROT90, snap = rot90(native, -1)) when the frame dir has one: the M1
    gate. Never-written palette entries are black on both sides (BLACK
    palette at power-on, tecmo16.cpp:688), so no pen substitution is needed.
  - always: the Python reference renderer sim/oracle/t16_render.py with
    rand_fallback (the RTL's deterministic choice for the four mixer
    branches where MAME writes machine().rand(), research item R6).
Pixels in MAME's rand() mask are excluded from the snapshot check and
counted (none occur in any M0 capture).

Usage:
  replay.py <run_dir>... [--jobs N] [--batch N] [--lat N] [--intv N]
            [--limit N] [--quiet] [--latch]
run_dir holds frames/NNNNNN/ (sim/mame/out/<run> or a synthetic scene dir).
Exit 0 only if every frame matches and no line overran its budget.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent / "oracle"))
from t16_render import render  # noqa: E402

BIN = HERE.parent / "build" / "m1" / "obj_dir" / "Vt16_video"
LBIN = HERE.parent / "build" / "m1_latch" / "obj_dir" / "Vt16_video"
REGIONS = ROOT / "sim" / "build" / "regions"
MACHINE = {"base": 0, "riot": 1, "ginkun": 2}
ROT90 = {"base"}
RAM_FILES = [("palette.bin", 8192), ("charram.bin", 4096), ("fgvram.bin", 4096), ("fgcram.bin", 4096),
             ("bgvram.bin", 4096), ("bgcram.bin", 4096), ("spr_buf_prev.bin", 4096)]
TARGET = {"pal": 0, "charram": 1, "fgvram": 2, "fgcram": 3, "bgvram": 4, "bgcram": 5,
          "scroll_char_x": 8, "scroll_char_y": 9, "fg_scroll_x": 10, "fg_scroll_y": 11,
          "bg_scroll_x": 12, "bg_scroll_y": 13, "flip": 16}


def ram(fd, name, nbytes, override=None):
    if override is not None and name in override:
        b = override[name]
    else:
        p = fd / name
        b = p.read_bytes() if p.exists() else b""
    return (b + bytes(nbytes))[:nbytes]


def make_t16f(fd, path, st=None, override=None, writes=()):
    """writes: list of (line, hcnt, target, addr, data, mask)."""
    st = st or json.loads((fd / "state.json").read_text())
    regs = [st["char_scroll_x"], st["char_scroll_y"], st["fg_scroll_x"], st["fg_scroll_y"],
            st["bg_scroll_x"], st["bg_scroll_y"]]
    hdr = (b"T16F" + bytes([MACHINE[st["machine"]], 1 if st["char_y_written"] else 0])
           + struct.pack("<I", len(writes)) + struct.pack("<6H", *[int(r) & 0xFFFF for r in regs])
           + bytes([1 if st["flip_x"] else 0, 0]))
    body = b"".join(ram(fd, n, sz, override) for n, sz in RAM_FILES)
    wl = b"".join(struct.pack("<HHBBHHH", ln, h, t, 0, a, d, m) for ln, h, t, a, d, m in writes)
    path.write_bytes(hdr + body + wl)
    return st


def load_rgb(out_path):
    raw = np.frombuffer(out_path.read_bytes(), dtype=np.uint8)
    if raw.size != 256 * 224 * 3:
        return None
    return raw.reshape(224, 256, 3).copy()


def check(fd, st, out_path, diffdir, model_only=False):
    """Return (ok, message, details)."""
    rgb = load_rgb(out_path)
    if rgb is None:
        return False, f"size {out_path.stat().st_size}", {}
    ref_m, rnd, _ = render(fd, rand_fallback=True)
    msgs = []
    det = {"rand_px": int(rnd.sum())}
    neq_m = np.any(rgb != ref_m, axis=-1)
    nm = int(neq_m.sum())
    det["model_rows"] = sorted(set(np.nonzero(neq_m)[0].tolist()))
    if nm:
        ys, xs = np.nonzero(neq_m)
        msgs.append(f"model {nm} px, first x={xs[0]} y={ys[0]} ref={tuple(int(v) for v in ref_m[ys[0], xs[0]])} "
                    f"rtl={tuple(int(v) for v in rgb[ys[0], xs[0]])}")
    snap_p = fd / "snap.png"
    tag = "model"
    if snap_p.exists() and not model_only:
        rot = (lambda a: np.rot90(a, -1)) if st["machine"] in ROT90 else (lambda a: a)
        view, vskip = rot(rgb), rot(rnd)
        ref = np.array(Image.open(snap_p).convert("RGB"))
        tag = "snap"
        if view.shape != ref.shape:
            return False, f"shape {view.shape} vs {ref.shape}", det
        neq = np.any(view != ref, axis=-1) & ~vskip
        n = int(neq.sum())
        # rows of the native (unrotated) frame that differ from MAME
        neq_native = np.rot90(neq, 1) if st["machine"] in ROT90 else neq
        det["snap_rows"] = sorted(set(np.nonzero(neq_native)[0].tolist()))
        if n:
            ys, xs = np.nonzero(neq)
            msgs.append(f"snap {n} px, first x={xs[0]} y={ys[0]} ref={tuple(int(v) for v in ref[ys[0], xs[0]])} "
                        f"rtl={tuple(int(v) for v in view[ys[0], xs[0]])}")
            diffdir.mkdir(parents=True, exist_ok=True)
            vis = np.concatenate([ref, view, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
            Image.fromarray(vis, "RGB").save(diffdir / f"{fd.name}_{tag}.png")
    return (not msgs), ("; ".join(msgs) if msgs else tag), det


def harness(td, items, setname, args, latch=False):
    (td / "list.txt").write_text("".join(f"{a} {b}\n" for a, b in items))
    cmd = [str(LBIN if latch else BIN), f"+sdram={REGIONS / setname / 'sdram.bin'}", f"+list={td / 'list.txt'}",
           f"+lat={args['lat']}", f"+intv={args['intv']}"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    stats = {"overruns": 0, "maxcyc": 0, "err": 0}
    for ln in p.stdout.splitlines():
        if ln.startswith("FRAME"):
            f = ln.split()
            stats["overruns"] += int(f[3])
            stats["maxcyc"] = max(stats["maxcyc"], int(f[5]))
            stats["err"] = max(stats["err"], int(f[7]))
    return p.returncode, p.stdout, p.stderr, stats


def run_batch(batch, setname, args, diffdir):
    with tempfile.TemporaryDirectory(prefix="t16m1_") as td:
        td = Path(td)
        items, states = [], []
        for fd in batch:
            inp, outp = td / f"{fd.name}.t16f", td / f"{fd.name}.rgb"
            states.append(make_t16f(fd, inp))
            items.append((inp, outp))
        rc, _, err, stats = harness(td, items, setname, args, args.get("latch", False))
        if rc not in (0, 1):
            return [(fd, False, f"harness rc {rc}: {err[-300:]}") for fd in batch], stats
        res = []
        for fd, st, (_, outp) in zip(batch, states, items):
            if not outp.exists():
                res.append((fd, False, "no output"))
                continue
            ok, msg, _ = check(fd, st, outp, diffdir)
            res.append((fd, ok, msg))
        return res, stats


def main(argv):
    opts = {"jobs": max(1, (os.cpu_count() or 4) // 2), "batch": 40, "lat": 9, "intv": 8, "limit": 0}
    runs, quiet = [], False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--quiet":
            quiet = True
        elif a == "--latch":
            opts["latch"] = True
        elif a.startswith("--"):
            opts[a[2:]] = int(argv[i + 1])
            i += 1
        else:
            runs.append(Path(a))
        i += 1
    if not BIN.exists():
        sys.exit(f"missing {BIN}; run make m1-build")
    rc = 0
    total = good_all = 0
    for run in runs:
        frames = sorted(p for p in (run / "frames").iterdir() if p.is_dir())
        if opts["limit"]:
            frames = frames[:opts["limit"]]
        # one harness process per machine (the machine is fixed at reset)
        groups = {}
        for fd in frames:
            st = json.loads((fd / "state.json").read_text())
            groups.setdefault(st["set"], []).append(fd)
        batches = [(s, fs[k:k + opts["batch"]]) for s, fs in groups.items() for k in range(0, len(fs), opts["batch"])]
        diffdir = run / "m1_diffs"
        good = over = maxcyc = err = 0
        tags = {}
        with ThreadPoolExecutor(max_workers=opts["jobs"]) as ex:
            for res, stats in ex.map(lambda b: run_batch(b[1], b[0], opts, diffdir), batches):
                over += stats["overruns"]
                maxcyc = max(maxcyc, stats["maxcyc"])
                err = max(err, stats["err"])
                for fd, ok, msg in res:
                    good += ok
                    if ok:
                        tags[msg] = tags.get(msg, 0) + 1
                    if not ok or not quiet:
                        print(f"{'MATCH' if ok else 'DIFF '} {run.name}/{fd.name}: {msg}", flush=True)
        print(f"== {run.name}: {good}/{len(frames)} frames exact ({tags}); line overruns {over}; snapshot errors {err}; "
              f"max render clocks/line {maxcyc} (budget 6144; ROM 1 req / {opts['intv']} clk, latency {opts['lat']})",
              flush=True)
        total += len(frames)
        good_all += good
        if good != len(frames) or over or err:
            rc = 1
    if len(runs) > 1:
        print(f"== total {good_all}/{total}")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
