#!/usr/bin/env python3
"""Count frames whose visible scan (lines 16-239) contains RAM writes that
change a stored value, per RAM class, from a HEAVY_LOG oracle run. MAME
renders the whole frame from the state at vblank (spec 10.1), so each such
write is a place where a renderer that reads RAM live during the scan would
show the old value above the write line and differ from MAME.

Usage: tools/midframe_writes.py <heavy_run_dir> <first_frame> <last_frame>
"""
import csv
import sys
from collections import Counter, defaultdict

CLASSES = {"fgvram", "fgcram", "bgvram", "bgcram", "charram", "pal", "spr"}


def main(argv):
    run, f0, f1 = argv[0], int(argv[1]), int(argv[2])
    mem = {}
    frames_with = defaultdict(set)
    changes = Counter()
    lines = defaultdict(Counter)
    for w in csv.DictReader(open(f"{run}/writes.csv")):
        c = w["class"]
        if c not in CLASSES:
            continue
        addr, data, mask = int(w["addr"], 16), int(w["data"], 16), int(w["mask"], 16)
        old = mem.get(addr, None)
        new = ((old or 0) & ~mask) | (data & mask)
        mem[addr] = new
        sf = int(w["scan_frame"])
        if w["visible"] == "1" and old is not None and old != new and f0 <= sf <= f1:
            frames_with[c].add(sf)
            changes[c] += 1
            lines[c][int(w["line"]) // 32 * 32] += 1
    n = f1 - f0 + 1
    for c in sorted(CLASSES):
        print(f"{c:8s} frames with value-changing visible writes {len(frames_with[c]):4d}/{n}, "
              f"changes {changes[c]}, by 32-line band {dict(sorted(lines[c].items()))}")


if __name__ == "__main__":
    main(sys.argv[1:])
