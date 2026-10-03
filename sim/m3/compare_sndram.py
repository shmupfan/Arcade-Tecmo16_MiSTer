#!/usr/bin/env python3
"""Sound RAM (0xF000-0xFBFF, 0xFFFE-0xFFFF) of the core against MAME at
every common dump frame.

    m3/compare_sndram.py OURS_DIR MAME_RAM_DIR [--stack 0xFB80]

OURS_DIR holds tb_sys NNNNNN.snd dumps (the +cap frames), MAME_RAM_DIR the
oracle's MAINRAM=1 ram/NNNNNN.snd. The sound CPU's stack (SP = 0xFC00 set
at reset, sound ROM 0x0003: "ld sp,0xfc00") holds interrupted context: MAME
runs the sound CPU in 600 Hz timeslices (t16:673), so at a frame notifier the
Z80 can be mid-routine, and stack bytes below the low-water mark --stack are
reported separately. A byte outside the stack that differs on 3 consecutive
dumps is persistent (a real state difference); others are transient.
"""
import argparse, pathlib, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ours"); ap.add_argument("mame")
    ap.add_argument("--stack", type=lambda x: int(x, 0), default=0xFB80)
    a = ap.parse_args()
    ours, mame = pathlib.Path(a.ours), pathlib.Path(a.mame)
    frames = sorted(int(p.stem) for p in ours.glob("*.snd") if (mame / p.name).exists())
    if not frames:
        print("no common dumps"); return 2
    def addr(i): return 0xF000 + i if i < 3072 else 0xFFFE + i - 3072
    bad = {}
    stack_frames = 0
    for n in frames:
        o = (ours / f"{n:06d}.snd").read_bytes(); m = (mame / f"{n:06d}.snd").read_bytes()
        d = {addr(i) for i in range(min(len(o), len(m))) if o[i] != m[i]}
        if any(x >= a.stack and x < 0xFC00 for x in d): stack_frames += 1
        d = {x for x in d if not (a.stack <= x < 0xFC00)}
        if d: bad[n] = d
    pers = {}
    for i, n in enumerate(frames[:-2]):
        c = bad.get(n, set()) & bad.get(frames[i + 1], set()) & bad.get(frames[i + 2], set())
        if c: pers[n] = c
    print(f"{len(frames)} dumps ({frames[0]}-{frames[-1]}); stack region {a.stack:#06x}-0xfbff differs on {stack_frames}")
    print(f"outside the stack: {len(bad)} dumps differ, {len(pers)} with a byte differing on 3 consecutive dumps")
    if pers:
        f0 = min(pers)
        print(f"  first persistent difference at frame {f0}: {sorted(hex(x) for x in pers[f0])[:16]}")
    if bad:
        allx = set().union(*bad.values())
        print(f"  addresses ever differing: {sorted(hex(x) for x in allx)[:20]}{' ...' if len(allx) > 20 else ''}")
    return 1 if pers else 0

if __name__ == "__main__":
    sys.exit(main())
