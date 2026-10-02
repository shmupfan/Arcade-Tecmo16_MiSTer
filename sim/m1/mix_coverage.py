#!/usr/bin/env python3
"""Mixer branch coverage (tecmo_mix.cpp:70-323) over frame dumps: how many
pixels take each branch of MAME's mixer, in MAME's order. Run over the
synthetic scenes (every branch must be hit, so the RTL comparison covers
it) and over the MAME captures (which branches the games use).

Usage: mix_coverage.py <run_dir>... [--require-all]
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "oracle"))
from t16_render import layers  # noqa: E402

# (name, MAME line) in evaluation order; "rand" = machine().rand() in MAME
BRANCHES = [
    ("behind: text", 111), ("behind: fg blended (rand)", 120), ("behind: fg", 122), ("behind: bg", 128),
    ("behind: sprite blended (rand)", 137), ("behind: sprite", 139),
    ("above bg: text", 148), ("above bg: fg blended + sprite blended", 157), ("above bg: fg blended", 164),
    ("above bg: fg", 170), ("above bg: sprite blended over bg", 180), ("above bg: sprite blended over pen", 185),
    ("above bg: sprite", 191),
    ("above fg: text", 200), ("above fg: sprite blended over fg blended (rand)", 214),
    ("above fg: sprite blended over fg", 216), ("above fg: sprite blended over bg", 222),
    ("above fg: sprite blended over pen", 228), ("above fg: sprite", 235),
    ("top: sprite blended over text", 251), ("top: sprite blended over fg blended (rand)", 261),
    ("top: sprite blended over fg", 263), ("top: sprite blended over bg", 269),
    ("top: sprite blended over pen", 274), ("top: sprite", 280),
    ("none: text", 289), ("none: fg blended over bg", 298), ("none: fg blended over pen", 302),
    ("none: fg", 307), ("none: bg", 312), ("none: background pen", 316),
]


def branch_counts(bg, fg, tx, sp):
    pri = (sp >> 10) & 3
    bl = ((sp >> 9) & 1) == 1
    spr = (sp & 15) != 0
    fgb = ((fg >> 8) & 1) == 1
    tx_on, fg_on, bg_on = (tx & 15) != 0, (fg & 15) != 0, (bg & 15) != 0
    b, a1, a2, t = spr & (pri == 3), spr & (pri == 2), spr & (pri == 1), spr & (pri == 0)
    conds = [
        b & tx_on, b & fg_on & fgb, b & fg_on, b & bg_on, b & bl, b,
        a1 & tx_on, a1 & fg_on & fgb & bl, a1 & fg_on & fgb, a1 & fg_on, a1 & bl & bg_on, a1 & bl, a1,
        a2 & tx_on, a2 & bl & fg_on & fgb, a2 & bl & fg_on, a2 & bl & bg_on, a2 & bl, a2,
        t & bl & tx_on, t & bl & fg_on & fgb, t & bl & fg_on, t & bl & bg_on, t & bl, t,
        ~spr & tx_on, ~spr & fg_on & fgb & bg_on, ~spr & fg_on & fgb, ~spr & fg_on, ~spr & bg_on, ~spr,
    ]
    done = np.zeros(bg.shape, dtype=bool)
    out = []
    for c in conds:
        c = c & ~done
        out.append(int(c.sum()))
        done |= c
    assert done.all()
    return out


def main(argv):
    req = "--require-all" in argv
    runs = [Path(a) for a in argv if not a.startswith("--")]
    tot = np.zeros(len(BRANCHES), dtype=np.int64)
    nf = 0
    for run in runs:
        for fd in sorted(p for p in (run / "frames").iterdir() if p.is_dir()):
            _, bg, fg, tx, sp, _ = layers(fd)
            v = slice(16, 240)
            tot += np.array(branch_counts(bg[v], fg[v], tx[v], sp[v]))
            nf += 1
    print(f"mixer branch coverage over {nf} frames ({', '.join(r.name for r in runs)}):")
    for (name, line), n in zip(BRANCHES, tot):
        print(f"  mix:{line:<4} {name:<52} {n:>12,}")
    missing = [name for (name, _), n in zip(BRANCHES, tot) if n == 0]
    print(f"branches never hit: {len(missing)}" + (f" ({'; '.join(missing)})" if missing else ""))
    return 1 if (req and missing) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
