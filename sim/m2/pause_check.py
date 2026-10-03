#!/usr/bin/env python3
"""M2 pause test (make m2-pause): with i_pause held from vblank F for N
frames, the 68000 and the sound board stop, so main, work and sound RAM at
every vblank F+1 .. F+N equal their state at vblank F (the dump is taken just
before the pause starts), no IRQ5 is taken during the pause, and after it the
game runs again (IRQs taken and RAM changing).

Usage: pause_check.py <run_dir> <F> <N>
"""
import sys
from pathlib import Path


def main(argv):
    d, f0, n = Path(argv[0]), int(argv[1]), int(argv[2])
    ok = True
    ref = {e: (d / f"{f0:06d}.{e}").read_bytes() for e in ("main", "work", "snd")}
    frozen = 0
    for f in range(f0 + 1, f0 + n + 1):
        cur = {e: (d / f"{f:06d}.{e}").read_bytes() for e in ref}
        bad = [e for e in ref if cur[e] != ref[e]]
        if bad:
            print(f"vblank {f}: {bad} changed during the pause")
            ok = False
        else:
            frozen += 1
    ft = {}
    for ln in (d / "ftrace.txt").read_text().split("\n"):
        p = ln.split()
        if len(p) == 5:
            ft[int(p[0])] = (int(p[1]), int(p[3]))
    during = sum(ft[f][1] for f in range(f0 + 1, f0 + n) if f in ft)
    after = sum(ft[f][0] for f in range(f0 + n + 1, f0 + n + 21) if f in ft)
    last = max(int(p.stem) for p in d.glob("*.main"))
    changed = (d / f"{last:06d}.main").read_bytes() != ref["main"]
    print(f"pause {f0}-{f0 + n}: RAM frozen on {frozen}/{n} vblanks; IRQ acknowledges during the pause {during}; "
          f"IRQ5 handler entries in the 20 frames after it {after}; main RAM at vblank {last} differs from the "
          f"pause state: {changed}")
    ok = ok and during == 0 and after > 0 and changed
    print("PAUSE " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
