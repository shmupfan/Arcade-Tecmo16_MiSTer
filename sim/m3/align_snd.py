#!/usr/bin/env python3
"""Align the core's sound event log (tb_sys +snd) with MAME's (t16_oracle
SNDLOG=1) and report where they first differ.

    m3/align_snd.py CORE.csv MAME.csv [--kinds LYOINRQ] [--show N] [--from F]

Times are put on one axis by the vblank-1 offset (the core counts the reset
and sound ROM download before power-on). Events are compared in order per
selected kind set; for each matched pair the time difference is reported.
"""
import argparse, csv, sys

def load(path, kinds):
    ev = []
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            k = row["kind"]
            if k is None or row.get("data") in (None, ""):
                continue                        # partial last line of a log still being written
            if k == "V" or k in kinds:
                d = 0 if k in "INQ" and k != "Q" else int(row["data"], 16)
                ev.append((float(row["t"]), int(row["frame"]), k, int(row["addr"], 16), d))
    # MAME logs from taps as each CPU runs its timeslice, so the 68000's and
    # the Z80's events arrive out of time order; sort on the emulated time
    # (stable, so same-time events keep their order)
    ev.sort(key=lambda e: e[0])
    return ev

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("core"); ap.add_argument("mame")
    ap.add_argument("--kinds", default="LYOIN")
    ap.add_argument("--show", type=int, default=12)
    ap.add_argument("--from", dest="ffrom", type=int, default=0)
    ap.add_argument("--maxdt", action="store_true", help="print the largest |dt| per kind before the first difference")
    a = ap.parse_args()
    c = load(a.core, a.kinds); m = load(a.mame, a.kinds)
    def v1(ev): return next(t for t, f, k, *_ in ev if k == "V" and f == 1)
    off = v1(c) - v1(m)
    c = [(t - off, f, k, ad, d) for t, f, k, ad, d in c if k != "V" and f >= a.ffrom]
    m = [(t, f, k, ad, d) for t, f, k, ad, d in m if k != "V" and f >= a.ffrom]
    n = min(len(c), len(m)); first = None; worst = {}
    for i in range(n):
        (tc, fc, kc, ac, dc), (tm, fm, km, am, dm) = c[i], m[i]
        if (kc, ac, dc) != (km, am, dm):
            first = i; break
        dt = (tc - tm) * 1e6
        if abs(dt) > abs(worst.get(kc, (0,))[0]): worst[kc] = (dt, fc)
    print(f"offset {off*1e3:.6f} ms; core {len(c)} events, MAME {len(m)}; kinds {a.kinds}")
    if a.maxdt:
        for k, (dt, f) in sorted(worst.items()): print(f"  largest |dt| {k}: {dt:+.2f} us at frame {f}")
    if first is None:
        print(f"identical for {n} events" + ("" if len(c) == len(m) else " (lengths differ)"))
        return 0
    print(f"first difference at event {first} (frame core {c[first][1]} / MAME {m[first][1]})")
    lo = max(0, first - a.show); hi = min(n, first + a.show)
    print(f"{'i':>7} {'core t(ms)':>12} {'f':>5} {'k':1} {'addr':>5} {'d':>3}   {'MAME t(ms)':>12} {'f':>5} {'k':1} {'addr':>5} {'d':>3}  dt(us)")
    for i in range(lo, hi):
        tc, fc, kc, ac, dc = c[i]; tm, fm, km, am, dm = m[i]
        mark = " <" if (kc, ac, dc) != (km, am, dm) else ""
        print(f"{i:7d} {tc*1e3:12.4f} {fc:5d} {kc} {ac:5x} {dc:3x}   {tm*1e3:12.4f} {fm:5d} {km} {am:5x} {dm:3x} {(tc-tm)*1e6:+8.2f}{mark}")
    return 1

if __name__ == "__main__":
    sys.exit(main())
