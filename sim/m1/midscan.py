#!/usr/bin/env python3
"""M1 mid-scan replay: every captured frame whose visible scan (lines
16-239) contains tile RAM, palette, scroll or flip writes, replayed through
the RTL with those writes applied at their beam position, and every
difference from MAME classified.

Input: the M0 frame dumps (sim/mame/out/<run>/frames) and the VISLOG rerun
of the same capture (sim/mame/out/vislog/<run>/vislog.csv, written by
mame/vislog_runs.py, which checks the rerun executed identically). A dump is
the state at vblank start (line 240), i.e. after the visible scan. The state
at the start of the visible scan is the dump with that frame's visible
writes undone, newest first (vislog records each word's value before the
write).

Per frame, three images:
  MAME   the snapshot: MAME draws the frame once at vblank start, so every
         visible-scan write shows on the whole frame (spec 10.1)
  INIT   t16_render.py of the state at the start of the visible scan
  LIVE   the RTL (default build) with the writes applied at (line, hpos):
         a line renderer reads tile RAM, scroll and flip for line L during
         line L-1 and the palette while line L is shown
  LATCH  the RTL LATCH build (snapshot at line 14): shows INIT on every line
Classes (LIVE):
  exact      LIVE == MAME
  no-op      the frame's visible writes change no value; LIVE must == MAME
  explained  LIVE differs from MAME only on rows whose line is at most
             last_write_line + 1, and equals INIT on every row whose line is
             below first_write_line (the image switches from the old state
             to MAME's between the first and last write, at line resolution)
  UNEXPLAINED anything else (the gate requires none)
LATCH must equal INIT on every row of every frame (checked) and differs from
MAME on every frame where INIT does.

Usage: midscan.py <run>... [--jobs N] [--limit N]
Writes build/m1/midscan_<run>.csv and prints a summary per run.
"""
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
SIM = HERE.parent
sys.path.insert(0, str(SIM / "oracle"))
sys.path.insert(0, str(HERE))
from t16_render import render  # noqa: E402
from replay import BIN, LBIN, REGIONS, ROT90, TARGET, load_rgb, make_t16f  # noqa: E402

OUT = SIM / "mame" / "out"
RAM_BASE = {
    "base": {"charram": 0x110000, "fgvram": 0x120000, "fgcram": 0x120800, "bgvram": 0x121000,
             "bgcram": 0x121800, "pal": 0x140000},
    "other": {"charram": 0x110000, "fgvram": 0x120000, "fgcram": 0x121000, "bgvram": 0x122000,
              "bgcram": 0x123000, "pal": 0x140000},
}
FILE_OF = {"charram": "charram.bin", "fgvram": "fgvram.bin", "fgcram": "fgcram.bin",
           "bgvram": "bgvram.bin", "bgcram": "bgcram.bin", "pal": "palette.bin"}
REG_KEY = {"scroll_char_x": "char_scroll_x", "scroll_char_y": "char_scroll_y", "fg_scroll_x": "fg_scroll_x",
           "fg_scroll_y": "fg_scroll_y", "bg_scroll_x": "bg_scroll_x", "bg_scroll_y": "bg_scroll_y"}


def read_vislog(run):
    by = {}
    with open(OUT / "vislog" / run / "vislog.csv") as f:
        for r in csv.DictReader(f):
            by.setdefault(int(r["scan_frame"]), []).append(
                (int(r["line"]), int(r["hpos"]), r["class"], int(r["addr"], 16), int(r["data"], 16),
                 int(r["mask"], 16), int(r["old"], 16), int(r["old_written"])))
    return by


def initial_state(fd, st, writes):
    """Undo the frame's visible writes (newest first). Returns (state,
    {file: bytes}, effective writes, harness write list)."""
    st0 = dict(st)
    rams = {n: bytearray((fd / n).read_bytes()) for n in FILE_OF.values()}
    bases = RAM_BASE["base" if st["machine"] == "base" else "other"]
    eff = []
    for (line, hpos, cls, addr, data, mask, old, ow) in reversed(writes):
        new = (old & ~mask | data & mask) & 0xFFFF
        if cls in FILE_OF:
            b = rams[FILE_OF[cls]]
            i = addr - bases[cls]
            i &= ~1
            if 0 <= i < len(b):
                b[i:i + 2] = old.to_bytes(2, "big")
        elif cls in REG_KEY:
            st0[REG_KEY[cls]] = old
            if cls == "scroll_char_y":
                st0["char_y_written"] = bool(ow)
        elif cls == "flip":
            st0["flip_x"] = old
            new = 255 if data & 1 else 0
        if new != old:
            eff.append(line)
    hw = []
    for (line, hpos, cls, addr, data, mask, old, ow) in writes:
        t = TARGET[cls]
        if cls in FILE_OF:
            a = ((addr - bases[cls]) >> 1) & 0xFFF
        else:
            a = 0
        hw.append((line, hpos * 384 // 256, t, a, data & 0xFFFF, mask & 0xFFFF))
    return st0, {k: bytes(v) for k, v in rams.items()}, eff, hw


def run_harness(binp, setname, items):
    with tempfile.TemporaryDirectory(prefix="t16ms_") as td:
        td = Path(td)
        lst = []
        for k, (fd, st, override, hw) in enumerate(items):
            inp, outp = td / f"{k}.t16f", td / f"{k}.rgb"
            make_t16f(fd, inp, st=st, override=override, writes=hw)
            lst.append((inp, outp))
        (td / "list.txt").write_text("".join(f"{a} {b}\n" for a, b in lst))
        p = subprocess.run([str(binp), f"+sdram={REGIONS / setname / 'sdram.bin'}", f"+list={td / 'list.txt'}"],
                           capture_output=True, text=True)
        outs = [load_rgb(o) if o.exists() else None for _, o in lst]
        return p.returncode, outs, p.stderr[-300:]


def native_snap(fd, st):
    snap = np.array(Image.open(fd / "snap.png").convert("RGB"))
    return np.rot90(snap, 1) if st["machine"] in ROT90 else snap


def rows(neq):
    return sorted(set(np.nonzero(neq.any(axis=-1) if neq.ndim == 3 else neq)[0].tolist()))


def classify_batch(run, setname, batch, vl):
    """batch: list of frame dirs. Returns result dicts."""
    items, meta = [], []
    tmp = Path(tempfile.mkdtemp(prefix="t16init_"))
    try:
        for fd in batch:
            st = json.loads((fd / "state.json").read_text())
            writes = vl[int(fd.name)]
            st0, rams, eff, hw = initial_state(fd, st, writes)
            # INIT reference: a copy of the dump with the undone RAM and state
            idir = tmp / fd.name
            shutil.copytree(fd, idir)
            for n, b in rams.items():
                (idir / n).write_bytes(b)
            (idir / "state.json").write_text(json.dumps(st0))
            items.append((fd, st0, rams, hw))
            meta.append((fd, st, idir, writes, eff))
        rc, live, err = run_harness(BIN, setname, items)
        rcl, latch, errl = run_harness(LBIN, setname, [(fd, st0, rams, []) for fd, st0, rams, _ in items])
        res = []
        for (fd, st, idir, writes, eff), lv, lt in zip(meta, live, latch):
            r = {"frame": fd.name, "writes": len(writes), "effective": len(eff),
                 "first_line": min(eff) if eff else -1, "last_line": max(eff) if eff else -1,
                 "classes": "+".join(sorted({w[2] for w in writes}))}
            if lv is None or lt is None:
                r["class"] = "UNEXPLAINED"
                r["note"] = f"no output rc {rc}/{rcl} {err}{errl}"
                res.append(r)
                continue
            mame = native_snap(fd, st)
            init, _, _ = render(idir, rand_fallback=True)
            d_live = np.any(lv != mame, axis=-1)
            d_init_latch = np.any(lt != init, axis=-1)
            d_latch = np.any(lt != mame, axis=-1)
            lrows = [16 + y for y in rows(d_live)]
            r["live_rows"] = f"{lrows[0]}-{lrows[-1]}" if lrows else ""
            r["live_px"] = int(d_live.sum())
            r["latch_px"] = int(d_latch.sum())
            r["latch_ok"] = int(not d_init_latch.any())
            if not d_live.any():
                r["class"] = "exact"
            elif not eff:
                r["class"] = "UNEXPLAINED"
                r["note"] = "no-op writes but LIVE differs"
            else:
                f0, f1 = min(eff), max(eff)
                below = all(y <= f1 + 1 for y in lrows)
                top_ok = not np.any(lv[:max(0, f0 - 16)] != init[:max(0, f0 - 16)])
                r["class"] = "explained" if (below and top_ok) else "UNEXPLAINED"
                if r["class"] != "explained":
                    r["note"] = f"rows beyond last write+1: {not below}; top differs from INIT: {not top_ok}"
            if not r["latch_ok"]:
                r["class"] = "UNEXPLAINED"
                r["note"] = (r.get("note", "") + " LATCH != INIT").strip()
            res.append(r)
        return res
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    jobs = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else 4
    limit = int(argv[argv.index("--limit") + 1]) if "--limit" in argv else 0
    runs = [a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or not argv[i - 1].startswith("--"))]
    outdir = SIM / "build" / "m1"
    outdir.mkdir(parents=True, exist_ok=True)
    rc = 0
    for run in runs:
        vl = read_vislog(run)
        frames = sorted(p for p in (OUT / run / "frames").iterdir() if p.is_dir() and int(p.name) in vl)
        if limit:
            frames = frames[:limit]
        if not frames:
            print(f"== {run}: no frames with visible-scan writes")
            continue
        setname = json.loads((frames[0] / "state.json").read_text())["set"]
        batches = [frames[k:k + 30] for k in range(0, len(frames), 30)]
        results = []
        with ThreadPoolExecutor(jobs) as ex:
            for res in ex.map(lambda b: classify_batch(run, setname, b, vl), batches):
                results += res
        keys = ["frame", "class", "writes", "effective", "first_line", "last_line", "classes",
                "live_rows", "live_px", "latch_px", "latch_ok", "note"]
        with open(outdir / f"midscan_{run}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            for r in results:
                w.writerow({k: r.get(k, "") for k in keys})
        cnt = {}
        for r in results:
            cnt[r["class"]] = cnt.get(r["class"], 0) + 1
        nframes = sum(1 for p in (OUT / run / "frames").iterdir() if p.is_dir())
        latch_diff = sum(1 for r in results if r.get("latch_px"))
        print(f"== {run}: {nframes} captured frames, {len(frames)} with visible-scan writes, "
              f"{sum(1 for r in results if r['effective'])} with value-changing ones; LIVE {cnt}; "
              f"LATCH differs from MAME on {latch_diff}", flush=True)
        for r in results:
            if r["class"] == "UNEXPLAINED":
                print(f"   UNEXPLAINED {run}/{r['frame']}: {r.get('note', '')} rows {r.get('live_rows')}")
        if cnt.get("UNEXPLAINED"):
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
