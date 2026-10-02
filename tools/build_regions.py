#!/usr/bin/env python3
"""M0.2: rebuild every MAME region exactly as the ROM_START block loads it,
write per-region .bin/.hex files for the Verilator harness, and emit the
SDRAM image in the fixed layout below (PLAN 4.3).

Outputs (under sim/build/regions/<set>/, gitignored):
  <region>.bin   logical byte stream (maincpu: byte 2n = high byte of word n,
                 the 68000 big-endian view MAME's region dump shows)
  <region>.hex   $readmemh text: maincpu one word per line (4 hex digits),
                 other regions one byte per line
  sdram.bin      SDRAM image, byte offsets per SDRAM_SLOTS, same byte order
                 as the .bin files
  manifest.json  region sizes, sha1s, SDRAM placement

Usage: tools/build_regions.py [--no-hex] [set ...]    (default: all sets)
"""
import hashlib
import json
import sys

from romdefs import ROOT, parse_driver, zip_index, build_region

OUT = ROOT / "sim" / "build" / "regions"

# PLAN 4.3: base, capacity. Every region of every set fits its slot
# without truncation (checked below).
SDRAM_SLOTS = {
    "maincpu":  (0x000000, 0x080000),
    "bgtiles":  (0x080000, 0x100000),
    "sprites":  (0x180000, 0x100000),
    "fgtiles":  (0x280000, 0x020000),
    "audiocpu": (0x2a0000, 0x010000),
    "oki":      (0x2b0000, 0x040000),
}
SDRAM_END = 0x2f0000
UNUSED = set()

# Region sizes from the ROM_START blocks (spec, Appendix A), checked so a
# parser or spec error cannot pass silently. All three machine configs
# (base, ginkun, riot) load the same region sizes.
_SIZES = dict(maincpu=0x80000, audiocpu=0x10000, fgtiles=0x20000, bgtiles=0x100000,
              sprites=0x100000, oki=0x40000)
SPEC_REGIONS = {"base": _SIZES, "ginkun": _SIZES, "riot": _SIZES}


def write_hex(path, data, width):
    if width == 16:
        lines = ["%02x%02x" % (data[i], data[i + 1]) for i in range(0, len(data), 2)]
    else:
        lines = ["%02x" % b for b in data]
    path.write_text("\n".join(lines) + "\n")


def build(name, sets, hexout=True):
    rs = sets[name]
    _, files, _ = zip_index(name, sets)
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    sdram = bytearray(SDRAM_END)
    manifest = {"set": name, "parent": rs.parent, "machine": rs.machine, "rot": rs.rot,
                "inputs": rs.inputs, "regions": {}, "sdram_end": SDRAM_END}
    errors = []
    for region in rs.regions:
        img = build_region(region, files)
        width = 16 if region.tag == "maincpu" else 8
        (d / f"{region.tag}.bin").write_bytes(img)
        if hexout and region.tag not in UNUSED:
            write_hex(d / f"{region.tag}.hex", img, width)
        entry = {"size": len(img), "width": width, "sha1": hashlib.sha1(img).hexdigest(),
                 "line": region.line}
        if region.tag in SDRAM_SLOTS:
            base, cap = SDRAM_SLOTS[region.tag]
            if len(img) > cap:
                errors.append(f"{region.tag}: {len(img):#x} exceeds slot {cap:#x}")
            sdram[base: base + len(img)] = img[:cap]
            entry["sdram_base"] = base
        elif region.tag not in UNUSED:
            errors.append(f"{region.tag}: no SDRAM slot")
        manifest["regions"][region.tag] = entry
    (d / "sdram.bin").write_bytes(bytes(sdram))
    (d / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    got = {t: e["size"] for t, e in manifest["regions"].items() if t not in UNUSED}
    if got != SPEC_REGIONS[rs.machine]:
        errors.append(f"regions {got} != spec {SPEC_REGIONS[rs.machine]}")
    return manifest, errors


def main(argv):
    hexout = "--no-hex" not in argv
    argv = [a for a in argv if not a.startswith("--")]
    sets = parse_driver()
    todo = argv or list(sets)
    fails = 0
    for name in todo:
        man, errors = build(name, sets, hexout)
        tot = sum(e["size"] for t, e in man["regions"].items() if t not in UNUSED)
        print(f"{'OK ' if not errors else 'BAD'} {name:11s} {len(man['regions'])} regions, "
              f"{tot // 1024} KB")
        for e in errors:
            print("     " + e)
        fails += bool(errors)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
