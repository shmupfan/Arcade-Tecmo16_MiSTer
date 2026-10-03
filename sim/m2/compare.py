#!/usr/bin/env python3
"""M2: compare a t16_sys boot run (m2/tb_sys.cpp) with the MAME oracle.

Inputs: our run dir (cap dumps, io.txt, ftrace.txt, events.txt), the M0
capture of the same run (sim/mame/out/<run>: frames/NNNNNN with the video
state and snapshot, writes.csv, frames.csv) and the M2 MAME run
(sim/mame/out/m2ram_<run>: ram/NNNNNN.main/.work/.snd).

Checks:
1. IRQ trace: per frame, writes to 0x150030-31 (the IRQ5 handler's first
   instruction, one per IRQ taken) and 0x150020-21 (IRQ5 clear), ours against
   frames.csv. The first frame that differs is reported.
2. I/O stream: every write to the flip, sound latch, IRQ and video register
   ports (the classes MAME logs in writes.csv), in order, value and lane
   mask; beam position deltas in pixels (MAME hpos x 1.5: its 256-pixel
   screen line equals our 384-pixel line in the parity raster).
3. State at vblank N (MAME frame N's notifier): palette, text, fg/bg tile
   RAMs, live sprite RAM, the sprite buffer, scroll registers, text-y flag,
   flip (M0 capture), main RAM, work RAM and sound RAM (M2 run). A
   difference is transient if the next dumped vblank matches again.
4. Images: our image N (scanned between vblank N-1 and N) against MAME's
   snapshot of frame N.
     exact      identical
     midscan    our own log has tile RAM, palette, scroll or flip writes
                during the visible scan (lines 16-239) of image N: the core
                reads live (PLAN 4.1.1), MAME draws the frame once at vblank
                start. Explained if every row above the first such write
                equals t16_render.py of the state at the start of the
                visible scan (our vblank N-1 dump plus our writes before
                line 16) and every row below the last write + 1 equals
                MAME's snapshot.
     overrun    a line pass overran its budget during image N (events.txt):
                R10, the sprite list exceeds the line pass capacity (the
                boot RAM test fills sprite RAM with 0xFFFF: 256 64x64
                sprites, 2,048 8-pixel cells per line)
     DIFF       anything else
Exit 0 only if no unexplained image, no persistent state difference and no
I/O or IRQ trace mismatch.

Usage: compare.py <ours> <m0_run> <m2ram_run> [--quiet] [--diff DIR] [--until N]
"""
import csv
import json
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "oracle"))
from t16_render import render  # noqa: E402

MACHINES = {"base": 0, "riot": 1, "ginkun": 2}
# Riot runs a small preemptive task kernel: its IRQ5 path saves the
# interrupted task's registers (movem.l d0-a5, PC, SR) into a task control
# block at A6 = 0x10000a + offset (code at 0x117e-0x11ac). Those words are the
# interrupted context, timing dependent like the stack (R16). TCBs found by a
# MAME write tap on the save instruction (PC 0x119e) over 12,000 attract
# frames: A6 = 0x1000fa, 0x10014a, 0x10028a; saved area A6+2 .. A6+0x3f.
TASK_CONTEXT = {"riot": [(a + 2, a + 0x40) for a in (0x1000fa, 0x10014a, 0x10028a)]}
VIS0, VIS1 = 16, 239


# ---------------------------------------------------------------- maps
def tile_map(machine):
    if machine == "base":
        return {"charram": (0x110000, 0x1000), "fgvram": (0x120000, 0x800), "fgcram": (0x120800, 0x800),
                "bgvram": (0x121000, 0x800), "bgcram": (0x121800, 0x800)}
    return {"charram": (0x110000, 0x1000), "fgvram": (0x120000, 0x1000), "fgcram": (0x121000, 0x1000),
            "bgvram": (0x122000, 0x1000), "bgcram": (0x123000, 0x1000)}


VREG = {0x160000: 0, 0x160006: 1, 0x16000c: 2, 0x160012: 3, 0x160018: 4, 0x16001e: 5}


def classify_addr(addr, machine):
    """Name of the display state an address belongs to, or None."""
    if 0x140000 <= addr < 0x142000:
        return "pal"
    for k, (b, n) in tile_map(machine).items():
        if b <= addr < b + n:
            return k
    if addr & ~1 == 0x150000:
        return "flip"
    if (addr & ~1) in VREG:
        return "vreg"
    return None


# ---------------------------------------------------------------- loaders
def load_ftrace_mame(run):
    out = {}
    with open(run / "frames.csv") as f:
        for r in csv.DictReader(f):
            out[int(r["frame"])] = (int(r["irq31"]), int(r["irq21"]))
    return out


def load_ftrace_ours(p):
    out = {}
    for ln in p.read_text().split("\n"):
        f = ln.split()
        if len(f) == 5:
            out[int(f[0])] = (int(f[1]), int(f[2]))
    return out


def load_io_ours(p):
    out = []
    for ln in p.read_text().split("\n"):
        f = ln.split()
        if len(f) != 6:
            continue
        a = int(f[3], 16)
        if logged_by_mame(a):
            out.append((int(f[0]), int(f[1]), int(f[2]), a, int(f[4], 16), int(f[5], 16)))
    return out


def logged_by_mame(a):
    a &= ~1
    return a in (0x150000, 0x150010, 0x150020, 0x150030) or 0x150040 <= a < 0x150060 or 0x160000 <= a < 0x160020


def load_io_mame(run):
    out = []
    with open(run / "writes.csv") as f:
        rd = csv.reader(f)
        next(rd)
        for r in rd:
            a = int(r[6], 16)
            if not logged_by_mame(a) or r[5] == "romw":
                continue
            out.append((int(r[0]), int(r[1]), int(r[2]), a & ~1, int(r[7], 16), int(r[8], 16)))
    return out


def words(b):
    return np.frombuffer(b, dtype=">u2").astype(np.int64)


# ---------------------------------------------------------------- checks
def check_ftrace(ours, mame, last):
    first = None
    n = 0
    for f in range(1, last + 1):
        if f not in ours or f not in mame:
            continue
        n += 1
        if ours[f] != mame[f]:
            first = (f, ours[f], mame[f])
            break
    return n, first


def check_io(ours, mame, last):
    ours = [w for w in ours if w[0] < last]
    mame = [w for w in mame if w[0] < last]
    first = None
    deltas = []
    for i, (a, b) in enumerate(zip(ours, mame)):
        # 0x150020/0x150030: the IRQ5 handler writes D0 without setting it
        # ("move.b D0, $150031", t16:348-351), so the value is the interrupted
        # code's D0, which depends on where the interrupt landed (R16): only
        # the address and lanes are compared
        dmask = 0 if (a[3] & ~1) in (0x150020, 0x150030) else a[5]
        if (a[3] & ~1, a[5], a[4] & dmask) != (b[3] & ~1, b[5], b[4] & dmask):
            first = (i, a, b)
            break
        pa = (a[0] * 256 + (a[1] - 240) % 256) * 384 + a[2]
        pb = (b[0] * 256 + (b[1] - 240) % 256) * 384 + b[2] * 1.5
        deltas.append(pa - pb)
    if first is None and len(ours) != len(mame):
        n = min(len(ours), len(mame))
        first = (n, ours[n] if n < len(ours) else None, mame[n] if n < len(mame) else None)
    return len(ours), len(mame), first, deltas


def state_files(ours, n, fd, ramd, machine):
    """Pairs (name, ours bytes, mame bytes) of the state at vblank n."""
    b = ours / f"{n:06d}"
    nb = 2048 if machine == "base" else 4096
    pairs = []

    def add(name, ofile, mpath, size=None):
        if not mpath.exists() or not Path(str(b) + ofile).exists():
            return
        o = Path(str(b) + ofile).read_bytes()
        m = mpath.read_bytes()
        if size:
            o, m = o[:size], m[:size]
        pairs.append((name, o, m))
    if fd is not None:
        add("palette", ".pal", fd / "palette.bin")
        add("char", ".char", fd / "charram.bin")
        add("fgv", ".fgv", fd / "fgvram.bin", nb)
        add("fgc", ".fgc", fd / "fgcram.bin", nb)
        add("bgv", ".bgv", fd / "bgvram.bin", nb)
        add("bgc", ".bgc", fd / "bgcram.bin", nb)
        add("spr_live", ".spr", fd / "spr_live.bin")
        add("spr_buf", ".sprb2", fd / "spr_buf.bin")
    if ramd is not None:
        add("main", ".main", ramd / f"{n:06d}.main")
        add("work", ".work", ramd / f"{n:06d}.work")
        add("snd", ".snd", ramd / f"{n:06d}.snd")
    return pairs


def regs_ours(ours, n):
    p = ours / f"{n:06d}.regs"
    if not p.exists():
        return None
    v = [int(x) for x in p.read_text().split()]
    return {"char_scroll_x": v[0], "char_scroll_y": v[1], "fg_scroll_x": v[2], "fg_scroll_y": v[3],
            "bg_scroll_x": v[4], "bg_scroll_y": v[5], "char_y_written": bool(v[6]), "flip": bool(v[7])}


def regs_mame(st):
    return {k: st[k] & 0xFFFF for k in ("char_scroll_x", "char_scroll_y", "fg_scroll_x", "fg_scroll_y",
                                        "bg_scroll_x", "bg_scroll_y")} | {
        "char_y_written": bool(st["char_y_written"]), "flip": bool(st["flip_x"])}


# ---------------------------------------------------------------- images
def load_rgb(p):
    raw = np.frombuffer(p.read_bytes(), dtype=np.uint8)
    if raw.size != 256 * 224 * 3:
        return None
    return raw.reshape(224, 256, 3).copy()


def snap_native(fd, machine):
    ref = np.array(Image.open(fd / "snap.png").convert("RGB"))
    return np.rot90(ref, 1) if machine == "base" else ref      # snap = rot90(native, -1) for ROT90


def read_wlog(p):
    out = []
    if not p.exists():
        return out
    for ln in p.read_text().split("\n"):
        f = ln.split()
        if len(f) == 5:
            out.append((int(f[0]), int(f[1]), int(f[2], 16), int(f[3], 16), int(f[4], 16)))
    return out


def init_render(ours, n, setname, machine, wlog):
    """t16_render of the state at the start of image n's visible scan: our
    vblank n-1 dump plus our writes of image n's window before line 16."""
    prev = ours / f"{n - 1:06d}"
    if not Path(str(prev) + ".pal").exists() or not Path(str(prev) + ".sprb2").exists():
        return None
    st = regs_ours(ours, n - 1)
    mem = {"pal": bytearray(Path(str(prev) + ".pal").read_bytes()),
           "charram": bytearray(Path(str(prev) + ".char").read_bytes())}
    for k, ext in (("fgvram", ".fgv"), ("fgcram", ".fgc"), ("bgvram", ".bgv"), ("bgcram", ".bgc")):
        mem[k] = bytearray(Path(str(prev) + ext).read_bytes())
    tm = tile_map(machine)
    for line, h, a, d, m in wlog:
        if VIS0 <= line <= VIS1:
            break
        c = classify_addr(a, machine)
        if c is None:
            continue
        if c == "flip":
            st["flip"] = bool(d & 1)
            continue
        if c == "vreg":
            k = ["char_scroll_x", "char_scroll_y", "fg_scroll_x", "fg_scroll_y", "bg_scroll_x", "bg_scroll_y"][VREG[a & ~1]]
            st[k] = (st[k] & ~m) | (d & m)
            if k == "char_scroll_y":
                st["char_y_written"] = True
            continue
        off = (a & ~1) - (0x140000 if c == "pal" else tm[c][0])
        buf = mem[c]
        if m & 0xFF00:
            buf[off] = d >> 8
        if m & 0x00FF:
            buf[off + 1] = d & 0xFF
    with tempfile.TemporaryDirectory(prefix="t16m2_") as td:
        td = Path(td)
        nb = 2048 if machine == "base" else 4096
        (td / "palette.bin").write_bytes(bytes(mem["pal"]))
        (td / "charram.bin").write_bytes(bytes(mem["charram"]))
        for k in ("fgvram", "fgcram", "bgvram", "bgcram"):
            (td / f"{k}.bin").write_bytes(bytes(mem[k][:nb]))
        (td / "spr_buf_prev.bin").write_bytes(Path(str(prev) + ".sprb2").read_bytes())
        js = {"set": setname, "machine": machine, "flip_x": 255 if st["flip"] else 0,
              "char_y_written": st["char_y_written"]}
        for k in ("char_scroll_x", "char_scroll_y", "fg_scroll_x", "fg_scroll_y", "bg_scroll_x", "bg_scroll_y"):
            js[k] = st[k]
        (td / "state.json").write_text(json.dumps(js))
        rgb, _, _ = render(td, rand_fallback=True)
    return rgb


def image_check(ours, n, fd, setname, machine, overrun_frames, diffdir):
    p = ours / f"{n:06d}.rgb"
    if not p.exists() or not (fd / "snap.png").exists():
        return None, ""
    rgb = load_rgb(p)
    if rgb is None:
        return "DIFF", "bad size"
    ref = snap_native(fd, machine)
    neq = np.any(rgb != ref, axis=-1)
    if not neq.any():
        return "exact", ""
    rows = np.nonzero(neq.any(axis=1))[0]
    wlog = read_wlog(ours / f"{n:06d}.wlog")
    vis = [(ln, h) for ln, h, a, d, m in wlog if VIS0 <= ln <= VIS1 and classify_addr(a, machine)]
    if vis:
        first = min(v[0] for v in vis) - VIS0
        last = max(v[0] for v in vis) - VIS0
        init = init_render(ours, n, setname, machine, wlog)
        above_ok = init is not None and not np.any(np.any(rgb[:max(first, 0)] != init[:max(first, 0)], axis=-1))
        below_ok = not neq[last + 2:].any()
        if above_ok and below_ok:
            return "midscan", f"rows {rows[0]}-{rows[-1]}, writes on lines {first + VIS0}-{last + VIS0}"
        msg = f"midscan UNEXPLAINED (above_ok {above_ok}, below_ok {below_ok}) rows {rows[0]}-{rows[-1]}, writes {first + VIS0}-{last + VIS0}"
    elif n in overrun_frames:
        return "overrun", f"{int(neq.sum())} px, rows {rows[0]}-{rows[-1]}"
    else:
        msg = f"{int(neq.sum())} px, rows {rows[0]}-{rows[-1]}"
    if diffdir:
        diffdir.mkdir(parents=True, exist_ok=True)
        vis_img = np.concatenate([ref, rgb, (neq[..., None] * np.array([255, 0, 255])).astype(np.uint8)], axis=1)
        Image.fromarray(vis_img, "RGB").save(diffdir / f"{n:06d}.png")
    return "DIFF", msg


# ---------------------------------------------------------------- main
def main(argv):
    quiet = "--quiet" in argv
    diffdir = None
    until = None
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--diff":
            diffdir = Path(argv[i + 1]); i += 2; continue
        if argv[i] == "--until":
            until = int(argv[i + 1]); i += 2; continue
        if not argv[i].startswith("--"):
            args.append(Path(argv[i]))
        i += 1
    ours, m0, m2 = args
    frames = sorted(int(p.name) for p in (m0 / "frames").iterdir() if p.is_dir())
    st0 = json.loads((m0 / "frames" / f"{frames[0]:06d}" / "state.json").read_text())
    setname, machine = st0["set"], st0["machine"]
    done = [int(p.stem) for p in ours.glob("*.rgb")]
    last = max(done) if done else 0
    if until:
        last = min(last, until)
    frames = [f for f in frames if f <= last]
    rc = 0

    # 1. IRQ trace
    ft_o = load_ftrace_ours(ours / "ftrace.txt")
    ft_m = load_ftrace_mame(m0)
    nft, first_ft = check_ftrace(ft_o, ft_m, last)
    print(f"irq trace: {nft} frames compared, first difference "
          f"{'none' if first_ft is None else first_ft}")
    if first_ft:
        rc = 1

    # 2. I/O stream, up to the last frame whose log is complete (the harness
    # flushes io.txt and ftrace.txt together every 100 frames)
    io_o, io_m = load_io_ours(ours / "io.txt"), load_io_mame(m0)
    io_last = min(last, max(ft_o) if ft_o else 0)
    no, nm, first_io, deltas = check_io(io_o, io_m, io_last)
    d = np.array(deltas) if deltas else np.zeros(1)
    print(f"io stream (frames < {io_last}): ours {no} writes, MAME {nm}, first mismatch {'none' if first_io is None else first_io}; "
          f"beam delta px min {d.min():.1f} max {d.max():.1f} mean {d.mean():.2f}")
    if first_io:
        rc = 1

    # 3. state
    ramdir = m2 / "ram" if (m2 / "ram").exists() else None
    bad = {}
    snd_bad = {}
    # The IRQ5 exception frame (SR and return PC, the 6 bytes below the
    # initial supervisor stack pointer from vector 0) holds the address the
    # main loop was interrupted at: it differs whenever the interrupt lands a
    # few CPU cycles apart (fx68k's autovector timing, R16) and carries no
    # game state. Listed separately, never a gate failure.
    sdram = (HERE.parent / "build" / "regions" / setname / "maincpu.bin").read_bytes()
    ssp = int.from_bytes(sdram[0:4], "big") & 0xFFFFFF
    exc_lo, exc_hi = ssp - 6, ssp
    irq_frame = {}
    main_words = {}
    # Stack: every word between the stack's low-water mark (MAME, STACKLOW=1
    # run of the same capture: the lowest SP at any main RAM write) and the
    # initial SSP. At a notifier the main loop runs with an empty stack (MAME:
    # SP = SSP whenever the CPU is in the main loop), so whatever the stack
    # holds belongs to IRQ5 handler instances, live (above SP) or dead (below
    # it): return addresses, and the registers of the interrupted code, whose
    # values depend on the instruction the interrupt landed on (R16). Reported
    # separately, never a gate failure on its own; a real divergence shows in
    # the I/O stream, the IRQ trace, the images or RAM outside the stack.
    dead_stack = {}
    task_ctx = {}
    stack_low = None
    slp = m0.parent / f"stacklow_{m0.name}" / "summary.txt"
    if slp.exists():
        for ln in slp.read_text().split("\n"):
            if ln.startswith("stack low-water"):
                stack_low = int(ln.split()[-1], 16)

    def sp_at(n):
        p = (ramdir / f"{n:06d}.cpu") if ramdir else None
        if p is None or not p.exists():
            return None
        return int(p.read_text().split()[0], 16) & 0xFFFFFF
    state_frames = 0
    first_state = None
    for n in frames:
        fd = m0 / "frames" / f"{n:06d}"
        pairs = state_files(ours, n, fd, ramdir, machine)
        if not pairs:
            continue
        state_frames += 1
        diffs = []
        for name, o, m in pairs:
            if o == m or name == "snd":
                continue
            if name == "main":
                w = {i for i in range(0, min(len(o), len(m)), 2) if o[i:i + 2] != m[i:i + 2]}
                frame_w = {i for i in w if exc_lo <= 0x100000 + i < exc_hi}
                if frame_w:
                    irq_frame[n] = sorted(0x100000 + i for i in frame_w)
                w -= frame_w
                sp = sp_at(n)
                lo = stack_low - 8 if stack_low is not None else (sp - 0x200 if sp is not None else ssp)
                stk = {i for i in w if lo <= 0x100000 + i < ssp}
                if stk:
                    dead_stack[n] = sorted(0x100000 + i for i in stk)
                w -= stk
                ctx = {i for i in w if any(a <= 0x100000 + i < b for a, b in TASK_CONTEXT.get(setname, ()))}
                if ctx:
                    task_ctx[n] = sorted(0x100000 + i for i in ctx)
                w -= ctx
                if not w:
                    continue
                main_words[n] = w
            diffs.append(name)
        for name, o, m in pairs:
            if name == "snd" and o != m:
                snd_bad[n] = {i for i in range(min(len(o), len(m))) if o[i] != m[i]}
        ro, rm = regs_ours(ours, n), regs_mame(json.loads((fd / "state.json").read_text()))
        if ro is not None and ro != rm:
            diffs.append("regs")
        if diffs:
            bad[n] = diffs
            if first_state is None:
                first_state = n
    # persistent: the same memory (for main RAM, the same word) differs on 5
    # or more consecutive dumps, or on the last dump of the run. Real game
    # state divergence never reconverges; a transient one (a write landing a
    # few cycles either side of the vblank instant, a task preempted at a
    # different instruction) does.
    dumped = [f for f in frames if (ours / f"{f:06d}.main").exists() or (ours / f"{f:06d}.pal").exists()]
    keys = sorted(bad)

    def items(n):
        out = set()
        for c in bad.get(n, ()):
            if c == "main":
                out |= {("main", w) for w in main_words.get(n, ())}
            else:
                out.add((c, None))
        return out
    persistent = {}
    run = {}
    for idx, n in enumerate(dumped):
        cur = items(n)
        run = {k: run.get(k, 0) + 1 for k in cur}
        for k, ln in run.items():
            if ln >= 5 or (idx == len(dumped) - 1):
                persistent.setdefault(n, set()).add(k[0] if k[1] is None else f"main {hex(0x100000 + k[1])}")
    persistent = {n: sorted(v) for n, v in persistent.items()}
    print(f"state: {state_frames} vblanks compared, {len(bad)} with a difference "
          f"({len(persistent)} persistent: 5+ consecutive dumps or the last); first {first_state} "
          f"{bad.get(first_state, '')}")
    print(f"IRQ5 exception frame ({hex(exc_lo)}-{hex(exc_hi - 1)}, interrupted PC): differs on "
          f"{len(irq_frame)} dumps; other stack words (low-water {hex(stack_low) if stack_low else 'none'} to {hex(ssp)}): {len(dead_stack)} dumps "
          f"{sorted({hex(a) for v in dead_stack.values() for a in v})[:8]}; task context blocks: {len(task_ctx)} dumps "
          f"{sorted({hex(a) for v in task_ctx.values() for a in v})[:8]} (interrupted context, not state; R16)")
    for n in sorted(persistent)[:10]:
        print(f"  PERSISTENT at {n}: {persistent[n]}")
    if not quiet:
        for n in keys[:40]:
            extra = ""
            if n in main_words:
                extra = " main words " + ", ".join(hex(0x100000 + i) for i in sorted(main_words[n])[:6])
            print(f"  state {n}: {bad[n]}{extra}")
    # Sound RAM: informational (M3 verifies the sound streams). MAME runs the
    # sound CPU in timeslices of its 600 Hz quantum (t16:673), so at a frame
    # notifier it can stand up to 1.7 ms away from the main CPU's time: stack
    # bytes and work variables mid-update differ transiently. A byte that
    # differs on three consecutive dumps is listed as worth a look in M3.
    sk = sorted(snd_bad)
    dumps = [f for f in frames if (ours / f"{f:06d}.snd").exists()]
    pos = {f: i for i, f in enumerate(dumps)}
    sticky = set()
    for n in sk:
        i = pos.get(n)
        if i is None or i + 2 >= len(dumps):
            continue
        a, b = dumps[i + 1], dumps[i + 2]
        common = snd_bad[n] & snd_bad.get(a, set()) & snd_bad.get(b, set())
        sticky |= {0xf000 + x if x < 3072 else 0xfffe + x - 3072 for x in common}
    addrs = set()
    for v in snd_bad.values():
        addrs |= {0xf000 + x if x < 3072 else 0xfffe + x - 3072 for x in v}
    print(f"sound RAM (informational): {len(snd_bad)} of {len(dumps)} dumps differ, "
          f"addresses {sorted(hex(a) for a in addrs)[:12]}{'...' if len(addrs) > 12 else ''}; "
          f"differing on 3 consecutive dumps: {sorted(hex(a) for a in sticky)[:12]}")

    # 4. images
    overruns = set()
    ev = ours / "events.txt"
    if ev.exists():
        for ln in ev.read_text().split("\n"):
            f = ln.split()
            if len(f) > 3 and f[0] == "overrun":
                overruns.add(int(f[2]) + 1)     # pass during image vblank+1
    counts = {}
    unexplained = []
    for n in frames:
        fd = m0 / "frames" / f"{n:06d}"
        cls, msg = image_check(ours, n, fd, setname, machine, overruns, diffdir)
        if cls is None:
            continue
        counts[cls] = counts.get(cls, 0) + 1
        if cls == "DIFF":
            unexplained.append((n, msg))
        if not quiet and cls != "exact":
            print(f"  image {n}: {cls} {msg}")
    print(f"images: {sum(counts.values())} compared: {counts}")
    for n, msg in unexplained[:20]:
        print(f"  UNEXPLAINED image {n}: {msg}")
    if unexplained or persistent:
        rc = 1
    print(f"RESULT {'PASS' if rc == 0 else 'FAIL'} ({ours.name}, last frame {last})")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
