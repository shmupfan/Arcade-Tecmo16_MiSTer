#!/usr/bin/env python3
"""Per-frame comparison of the sound event logs (core tb_sys +snd against
MAME SNDLOG=1), frames 1..N where both logs are complete.

    m3/frame_summary.py CORE.csv MAME.csv [--kinds LYOIN] [--list 20]

Events are grouped by the vblank they follow (the "frame" column). For each
frame:
  same      identical sequence (kind, address, data) in identical order
  boundary  this frame and the next hold the same events as a pair: an event
            near the vblank falls on the other side of it
  reorder   the same events, in a different order (typically an NMI taken
            one instruction earlier or later against an interrupt-driven
            write; m3_findings 3)
  differ    different events (a different decision by the sound program)
Reports the counts, the first reorder and differ frames, and for "differ"
whether the following frames are back to "same" (a transient) or not.
"""
import argparse, csv, sys
from collections import defaultdict

def load(path, kinds):
    fr = defaultdict(list); last = 0
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            k = r["kind"]
            if k is None or r.get("data") in (None, ""): continue
            rows.append((float(r["t"]), int(r["frame"]), k, r["addr"], r["data"]))
    rows.sort(key=lambda x: x[0])
    for t, f, k, a, d in rows:
        if k == "V": last = max(last, f); continue
        if k not in kinds: continue
        if k in "IN": d = "0"
        fr[f].append((k, a, d))
    return fr, last

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("core"); ap.add_argument("mame")
    ap.add_argument("--kinds", default="LYOIN")
    ap.add_argument("--list", type=int, default=12)
    a = ap.parse_args()
    c, lc = load(a.core, a.kinds); m, lm = load(a.mame, a.kinds)
    n = min(lc, lm) - 1
    cls = {}
    for f in range(0, n + 1):
        x, y = c.get(f, []), m.get(f, [])
        cls[f] = "same" if x == y else ("reorder" if sorted(x) == sorted(y) else "differ")
    # an event a few microseconds from the vblank falls in the next frame on
    # one side (the core's sound CPU runs at a constant phase from MAME's,
    # section 3): a run of consecutive frames that matches as a whole is "boundary"
    f = 0
    while f <= n:
        if cls[f] != "differ":
            f += 1; continue
        g = f
        while g + 1 <= n and cls[g + 1] == "differ": g += 1
        if g > f:
            x = [e for h in range(f, g + 1) for e in c.get(h, [])]
            y = [e for h in range(f, g + 1) for e in m.get(h, [])]
            lab = "boundary" if x == y else ("reorder" if sorted(x) == sorted(y) else None)
            if lab:
                for h in range(f, g + 1): cls[h] = lab
        f = g + 1
    cnt = defaultdict(int)
    for v in cls.values(): cnt[v] += 1
    print(f"frames 0-{n}: same {cnt['same']}, boundary {cnt['boundary']}, reorder {cnt['reorder']}, differ {cnt['differ']} (kinds {a.kinds})")
    ro = [f for f in cls if cls[f] == "reorder"]; df = [f for f in cls if cls[f] == "differ"]
    if ro: print(f"  reorder frames: {ro[:a.list]}{' ...' if len(ro) > a.list else ''}")
    if df:
        print(f"  differ frames: {df[:a.list]}{' ...' if len(df) > a.list else ''}")
        # a run of consecutive differing frames that reaches the end = lasting divergence
        tail = n
        while tail >= 0 and cls[tail] == "differ": tail -= 1
        lasting = tail < n
        print(f"  lasting divergence from frame {tail + 1}" if lasting else "  every differing frame is followed by matching frames (transients)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
