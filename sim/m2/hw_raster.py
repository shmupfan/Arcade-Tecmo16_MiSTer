#!/usr/bin/env python3
"""M2: what the hardware-default raster (6 MHz, 384 x 264, MAME's TODO
guess t16:20) changes, against MAME's 59.17 Hz / 256-line raster. Both run
IRQ5 for 1000 us from line 240.

Per game (3,000 frames from power-on, make m2-hw):
  - IRQ5 handler entries per frame (writes to 0x150030-31) and IRQ5 clears
    (0x150020-21): distribution against MAME's frames.csv over the same
    frames of the parent's attract capture
  - the first frame where the per-frame trace differs from MAME's
  - gate counters (overruns after the boot RAM test, unmapped accesses)

Usage: hw_raster.py <build/m2_hw> <sim/mame/out>
"""
import csv
import sys
from collections import Counter
from pathlib import Path

RUN = {"fstarfrc": "fs_attract", "riot": "riot_attract", "ginkun": "ginkun_attract"}


def main(argv):
    hw, out = Path(argv[0]), Path(argv[1])
    for game, run in RUN.items():
        d = hw / game
        if not (d / "ftrace.txt").exists():
            print(f"{game}: no run")
            continue
        ours = {}
        for ln in (d / "ftrace.txt").read_text().split("\n"):
            f = ln.split()
            if len(f) == 5:
                ours[int(f[0])] = (int(f[1]), int(f[2]))
        mame = {}
        with open(out / run / "frames.csv") as f:
            for r in csv.DictReader(f):
                mame[int(r["frame"])] = (int(r["irq31"]), int(r["irq21"]))
        last = max(ours)
        first = next((n for n in range(1, last + 1) if n in mame and ours.get(n) != mame[n]), None)
        co = Counter(v[0] for n, v in ours.items() if n <= last)
        cm = Counter(mame[n][0] for n in range(1, last + 1) if n in mame)
        print(f"{game}: {last} frames; IRQ5 entries per frame, hw raster {dict(sorted(co.items()))}, "
              f"MAME {dict(sorted(cm.items()))}; first frame whose trace differs from MAME: {first}")
        print(f"  {(d / 'run.log').read_text().strip().splitlines()[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
