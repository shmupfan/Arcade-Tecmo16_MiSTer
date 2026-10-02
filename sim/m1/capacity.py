#!/usr/bin/env python3
"""Sprites-per-line probe (not a gate): how many 8-pixel sprite cells one
line can take before the line pass overruns its 6,144-clock budget, with
the pessimistic ROM port (one 32-bit read per 8 clocks, latency 9) and all
three tilemaps fetched. MAME has no per-line limit (its renderer draws the
whole list); the PCB's limit is unknown (research item, m1_findings).

For each sprite width (8, 16, 32, 64 pixels = 1, 2, 4, 8 cells) the probe
puts N enabled sprites across line 100 and finds the largest N with zero
overruns. The games' worst line in the M0 captures is 24 sprites / 146
cells (m0_findings 4).
Usage: capacity.py
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from make_scenes import Scene  # noqa: E402
from replay import BIN, REGIONS, make_t16f  # noqa: E402


def overruns(machine, setname, n, lx):
    rng = np.random.default_rng(n * 4 + lx)
    s = Scene(machine, 0, rng)
    for k in range(256):
        if k < n:
            cw = lx | ((lx if machine == "riot" else 0) << 2)
            s.sprite(k, 4, 0x100 + 64 * k, cw, 100, (k * 5) & 0xFF)
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        s.write(td / "sc", setname, 1)
        fd = td / "sc" / "frames" / "000001"
        make_t16f(fd, td / "a.t16f")
        (td / "l.txt").write_text(f"{td / 'a.t16f'} {td / 'a.rgb'}\n")
        p = subprocess.run([str(BIN), f"+sdram={REGIONS / setname / 'sdram.bin'}", f"+list={td / 'l.txt'}"],
                           capture_output=True, text=True)
        for ln in p.stdout.splitlines():
            if ln.startswith("FRAME"):
                f = ln.split()
                return int(f[3]), int(f[5])
    return None, None


def main():
    for machine, setname in (("base", "fstarfrc"), ("riot", "riot")):
        for lx in range(4):
            cells = 1 << lx
            lo, hi = 0, 256
            last_cyc = 0
            while lo < hi:
                mid = (lo + hi + 1) // 2
                ov, cyc = overruns(machine, setname, mid, lx)
                if ov == 0:
                    lo, last_cyc = mid, cyc
                else:
                    hi = mid - 1
            print(f"{setname}: {8 * cells}-pixel-wide sprites: {lo} on one line without overrun "
                  f"({lo * cells} cells{', the whole list' if lo == 256 else ''}; worst pass {last_cyc} clocks of 6,144)",
                  flush=True)


if __name__ == "__main__":
    main()
