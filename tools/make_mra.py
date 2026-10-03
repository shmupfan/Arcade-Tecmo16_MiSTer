#!/usr/bin/env python3
"""M4: generate the MRA files and prove each one reproduces the SDRAM image.

For every set the ROM stream the MiSTer assembles (index 0) must equal
sim/build/regions/<set>/sdram.bin byte for byte, up to the end of the last
region the core uses (PLAN 4.3 layout, tools/build_regions.py SDRAM_SLOTS;
t16_sdram writes the stream from byte 0). The generator records where every
output byte comes from (file + position, or a fill value) while replaying
the ROM_START loads with tools/romdefs.py semantics, then encodes the
sequence as MRA parts:
  linear run from one file      <part name crc offset length/>
  N-byte lane interleave        <interleave output="16|32"> one part per
                                source file (a lane may be inline fill data),
                                map nibble k = which byte of the part's
                                group lands in output byte k of the unit
  fill                          <part repeat="N">VV</part>
assemble() then replays the MRA with Main_MiSTer's mra_loader.cpp rules
(map nibble k = output byte k of the unit, rightmost nibble = lowest
address; offset/length/repeat/crc per part) from the zips and compares.

DIP switches come from the driver's INPUT_PORTS blocks (never typed by hand):
every PORT_DIPNAME becomes a <dip>; the default bytes are the ports' default
values. This driver has two 8-bit switch ports (the byte in the low half of
each 16-bit port): MRA byte 0 = DSW1, byte 1 = DSW2, so a DSW2 field at port
bit n is MRA bit 8 + n (t16_board puts byte 0 on DSW1 and byte 1 on DSW2).
MAME labels that contain commas (Final Star Force bonus lives) get "/" in
their place, since the MRA ids list is comma separated.

Usage: tools/make_mra.py [set ...]      (default: every set in the driver)
Writes releases/<Title>.mra (parents) and releases/_alternatives/_<Game>/
(clones); exit 0 only if every MRA verifies.
"""
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from romdefs import ROOT, DRIVER, parse_driver, zip_index      # noqa: E402
from build_regions import SDRAM_SLOTS, OUT as REGIONS          # noqa: E402

RBF = "tecmo16"                  # matches releases/Arcade-Tecmo16_YYYYMMDD.rbf
MACHINE_ID = {"base": 0, "riot": 1, "ginkun": 2}   # t16_board i_machine
OUTDIR = ROOT / "releases"
PARENT_GAME = {"fstarfrc": "Final Star Force", "riot": "Riot"}   # _alternatives/_<name>/ folder
DSW_PORTS = {"DSW1": 0, "DSW2": 8}   # MRA bit offset of each switch port

FILL = -1                        # src_file value for fill bytes (src_pos = value)


# ------------------------------------------------------------------ sources
def stream_sources(rs):
    """Per output byte: (file index, file position) arrays; file index FILL
    means a constant byte held in pos. Returns (fidx, fpos, crcs)."""
    placed = [(r, SDRAM_SLOTS[r.tag]) for r in rs.regions if r.tag in SDRAM_SLOTS]
    end = max(base + r.size for r, (base, _cap) in placed)
    fidx = np.full(end, FILL, dtype=np.int32)
    fpos = np.zeros(end, dtype=np.int64)
    crcs = []

    def fid(crc):
        if crc not in crcs:
            crcs.append(crc)
        return crcs.index(crc)

    for region, (base, cap) in placed:
        assert region.size <= cap, region.tag
        for ld in region.loads:
            if ld.no_dump:
                continue
            if ld.kind == "FILL":
                a = base + ld.offset
                fidx[a:a + ld.length] = FILL
                fpos[a:a + ld.length] = int(ld.crc, 16)
                continue
            f = fid(ld.crc)
            for kind, ofs, length, pos in ld.pieces:
                k = np.arange(length, dtype=np.int64)
                if kind == "LOAD":
                    dst = base + ofs + k
                elif kind == "LOAD16_BYTE":
                    dst = base + ofs + 2 * k
                elif kind == "LOAD32_BYTE":
                    dst = base + ofs + 4 * k
                elif kind == "LOAD32_WORD":
                    dst = base + ofs + 4 * (k // 2) + (k % 2)
                elif kind == "LOAD16_WORD_SWAP":
                    dst = base + ofs + (k ^ 1)
                else:
                    raise ValueError(kind)
                fidx[dst] = f
                fpos[dst] = pos + k
    return fidx, fpos, crcs


# ------------------------------------------------------------------ encoder
def _linear_len(fidx, fpos, p):
    """Length of the run at p: one file at consecutive positions, or one
    fill value."""
    n = len(fidx)
    f = fidx[p]
    seg_f = fidx[p:]
    if f == FILL:
        same = (seg_f == FILL) & (fpos[p:] == fpos[p])
    else:
        same = (seg_f == f) & (fpos[p:] == fpos[p] + np.arange(n - p))
    bad = np.flatnonzero(~same)
    return int(bad[0]) if len(bad) else n - p


def _lanes(fidx, fpos, p, unit):
    """Describe one unit at p as lane groups, or None if not a regular
    interleave: {file: [(lane, pos0), ...]} with consecutive positions per
    file, plus {lane: fill value}."""
    groups, fills = {}, {}
    for i in range(unit):
        f, q = int(fidx[p + i]), int(fpos[p + i])
        if f == FILL:
            fills[i] = q
        else:
            groups.setdefault(f, []).append((i, q))
    for f, lanes in groups.items():
        base = lanes[0][1]
        if any(q != base + j for j, (_i, q) in enumerate(lanes)):
            return None
    return groups, fills


def _interleave_len(fidx, fpos, p, unit):
    d = _lanes(fidx, fpos, p, unit)
    if d is None:
        return 0, None
    groups, fills = d
    n_units = (len(fidx) - p) // unit
    ok = np.ones(n_units, dtype=bool)
    k = np.arange(n_units, dtype=np.int64)
    for f, lanes in groups.items():
        m = len(lanes)
        for j, (i, q) in enumerate(lanes):
            idx = p + unit * k + i
            ok &= (fidx[idx] == f) & (fpos[idx] == q + m * k)
    for i, v in fills.items():
        idx = p + unit * k + i
        ok &= (fidx[idx] == FILL) & (fpos[idx] == v)
    bad = np.flatnonzero(~ok)
    return (int(bad[0]) if len(bad) else n_units), d


def encode(fidx, fpos):
    """-> list of ('lin', f, pos, n) | ('fill', v, n) | ('il', unit, k, groups, fills)."""
    out = []
    p, n = 0, len(fidx)
    while p < n:
        run = _linear_len(fidx, fpos, p)
        if fidx[p] == FILL:
            out.append(("fill", int(fpos[p]), run))
            p += run
            continue
        if run >= 64:
            out.append(("lin", int(fidx[p]), int(fpos[p]), run))
            p += run
            continue
        best = None
        for unit in (2, 4):          # the narrower form when it covers as much
            if p % unit or p + unit > n:
                continue
            k, d = _interleave_len(fidx, fpos, p, unit)
            if k >= 2 and (best is None or k * unit > best[0] * best[1]):
                best = (k, unit, d)
        if best:
            k, unit, (groups, fills) = best
            out.append(("il", unit, k, groups, fills))
            p += k * unit
        else:
            out.append(("lin", int(fidx[p]), int(fpos[p]), run))
            p += run
    return out


# ------------------------------------------------------------------ XML
def rom_element(rs, sets, fidx, fpos, crcs):
    names = {}
    for region in rs.regions:
        for ld in region.loads:
            if ld.crc and ld.name:
                names[ld.crc] = ld.name
    zips, s = [], rs.name
    while True:
        zips.append(f"{s}.zip")
        if not sets[s].parent:
            break
        s = sets[s].parent
    rom = ET.Element("rom", index="0", zip="|".join(zips), md5="none")

    def part(f, pos, length, mapv=None):
        e = ET.Element("part", name=names[crcs[f]], crc=crcs[f],
                       offset=f"0x{pos:X}", length=f"0x{length:X}")
        if mapv:
            e.set("map", mapv)
        return e

    def fill(v, cnt, mapv=None):
        e = ET.Element("part", repeat=f"0x{cnt:X}")
        if mapv:
            e.set("map", mapv)
        e.text = f"{v:02X}"
        return e

    for item in encode(fidx, fpos):
        if item[0] == "fill":
            rom.append(fill(item[1], item[2]))
        elif item[0] == "lin":
            rom.append(part(item[1], item[2], item[3]))
        else:
            _, unit, k, groups, fills = item
            il = ET.SubElement(rom, "interleave", output=str(8 * unit))
            for f, lanes in groups.items():
                nib = ["0"] * unit
                for j, (i, _q) in enumerate(lanes):
                    nib[i] = str(j + 1)
                il.append(part(f, lanes[0][1], len(lanes) * k, "".join(reversed(nib))))
            for i, v in fills.items():
                nib = ["0"] * unit
                nib[i] = "1"
                il.append(fill(v, k, "".join(reversed(nib))))
    return rom


# ------------------------------------------------------------------ assembler (mra_loader.cpp)
def assemble(mra_path, zipdir):
    root = ET.parse(mra_path).getroot()
    rom = next(r for r in root.findall("rom") if r.get("index") == "0")
    zips = [zipfile.ZipFile(zipdir / z) for z in rom.get("zip").split("|") if (zipdir / z).exists()]
    by_crc = {}
    for z in zips:
        for info in z.infolist():
            by_crc.setdefault("%08x" % info.CRC, (z, info))
    cache = {}
    out = bytearray()

    def data_of(part):
        if part.get("name"):
            crc = part.get("crc").lower()
            if crc not in cache:
                z, info = by_crc[crc]
                cache[crc] = z.read(info)
            d = cache[crc]
            off = int(part.get("offset", "0"), 0)
            ln = int(part.get("length", "-1"), 0)
            d = d[off:] if ln <= 0 else d[off:off + ln]
        else:
            d = bytes.fromhex("".join((part.text or "").split()))
        return d * int(part.get("repeat", "1"), 0)

    for el in rom:
        if el.tag == "part":
            out += data_of(el)
        elif el.tag == "interleave":
            unit = int(el.get("output"), 0) // 8
            base = len(out)
            arrs = []
            for part in el.findall("part"):
                nib = [int(c, 16) for c in reversed(part.get("map").rjust(unit, "0"))]
                d = np.frombuffer(data_of(part), dtype=np.uint8)
                used = [i for i in range(unit) if nib[i]]
                cnt = len(d) // len(used)
                arrs.append((nib, used, d, cnt))
            units = max(a[3] for a in arrs)
            buf = np.zeros(units * unit, dtype=np.uint8)
            for nib, used, d, cnt in arrs:
                per = len(used)
                for i in used:
                    buf[i:cnt * unit:unit] = d[nib[i] - 1:cnt * per:per]
            out += buf.tobytes()
    return bytes(out)


# ------------------------------------------------------------------ DIP switches from INPUT_PORTS
def _label(s):
    s = s.strip()
    m = re.match(r'DEF_STR\(\s*(\w+)\s*\)', s)
    if m:
        s = m.group(1)
        c = re.match(r"(\d+)C_(\d+)C$", s)
        if c:
            return f"{c.group(1)}C/{c.group(2)}C"
        return s.replace("_", " ")
    return s.strip('"').replace(",", "/")


def parse_dsw(inputs):
    """DSW1 and DSW2 of INPUT_PORTS_START(inputs): (dips, default) where dips
    is a list of (name, low_bit, nbits, {field_value: label}) in MRA bits
    (DSW1 bits 0-7, DSW2 bits 8-15)."""
    text = DRIVER.read_text().splitlines()
    i = next(n for n, ln in enumerate(text) if re.match(rf"static INPUT_PORTS_START\(\s*{inputs}\s*\)", ln))
    port, dips, default, cur = None, [], 0, None
    for ln in text[i + 1:]:
        if "INPUT_PORTS_END" in ln:
            break
        code = ln.split("//")[0]
        m = re.search(r'PORT_START\(\s*"(\w+)"', code)
        if m:
            port = m.group(1)
            continue
        if port not in DSW_PORTS:
            continue
        sh = DSW_PORTS[port]
        m = re.search(r"PORT_DIPNAME\(\s*(0x\w+)\s*,\s*(0x\w+)\s*,\s*(.+?)\s*\)\s*PORT_DIPLOCATION", code)
        if m:
            mask, dflt = int(m.group(1), 16), int(m.group(2), 16)
            assert mask <= 0xFF, f"switch field above bit 7: {code}"
            mask, dflt = mask << sh, dflt << sh
            lo = (mask & -mask).bit_length() - 1
            nb = mask.bit_length() - lo
            assert mask == ((1 << nb) - 1) << lo, f"non-contiguous DIP {code}"
            cur = (_label(m.group(3)), lo, nb, {}, mask)
            dips.append(cur)
            default |= dflt & mask
            continue
        m = re.search(r"PORT_DIPSETTING\s*\(\s*(0x\w+)\s*,\s*(.+?)\s*\)\s*$", code.strip())
        if m and cur:
            v = ((int(m.group(1), 16) << sh) & cur[4]) >> cur[1]
            cur[3].setdefault(v, _label(m.group(2)))
            continue
        m = re.search(r"PORT_SERVICE_DIPLOC\(\s*(0x\w+)\s*,\s*IP_ACTIVE_LOW", code)
        if m:
            mask = int(m.group(1), 16) << sh
            lo = mask.bit_length() - 1
            dips.append(("Service Mode", lo, 1, {0: "On", 1: "Off"}, mask))
            default |= mask
            cur = None
            continue
        m = re.search(r"PORT_DIPUNKNOWN_DIPLOC\(\s*(0x\w+)\s*,\s*(0x\w+)", code)
        if m:
            default |= (int(m.group(2), 16) & int(m.group(1), 16)) << sh
            cur = None
            continue
        m = re.search(r"PORT_DIPUNUSED_DIPLOC\(\s*(0x\w+)\s*,\s*IP_ACTIVE_LOW", code)
        if m:
            default |= int(m.group(1), 16) << sh
            cur = None
    return [d[:4] for d in dips], default


def switches(inputs):
    dips, default = parse_dsw(inputs)
    sw = ET.Element("switches", default=f"{default & 0xFF:02X},{default >> 8:02X}")
    for name, lo, nb, vals in dips:
        # MAME repeats a label for settings that behave alike; number the
        # repeats so the OSD can tell them apart, the default one unnumbered
        dv = (default >> lo) & ((1 << nb) - 1)
        order = [dv] + [v for v in range(1 << nb) if v != dv]
        ids, seen = {}, {}
        for v in order:
            lab = vals.get(v, "?")
            seen[lab] = seen.get(lab, 0) + 1
            ids[v] = lab if seen[lab] == 1 else f"{lab} ({seen[lab]})"
        ids = [ids[v] for v in range(1 << nb)]
        bits = str(lo) if nb == 1 else f"{lo},{lo + nb - 1}"
        ET.SubElement(sw, "dip", name=name, bits=bits, ids=",".join(ids))
    return sw, default


# ------------------------------------------------------------------ MRA
def title_of(setname):
    for ln in DRIVER.read_text().splitlines():
        m = re.match(r'GAME\(\s*(\d+),\s*(\w+),.*?,\s*"([^"]*)",\s*"([^"]*)"', ln)
        if m and m.group(2) == setname:
            return m.group(1), m.group(3), m.group(4)
    raise KeyError(setname)


def make(setname, sets):
    rs = sets[setname]
    year, maker, title = title_of(setname)
    fidx, fpos, crcs = stream_sources(rs)
    root = ET.Element("misterromdescription")
    for tag, val in (("name", title), ("setname", setname), ("rbf", RBF), ("mameversion", "0289"),
                     ("year", year), ("manufacturer", maker),
                     ("players", "2"),
                     ("joystick", "8-way"),
                     ("rotation", {"ROT90": "vertical (cw)", "ROT270": "vertical (ccw)"}.get(rs.rot, "horizontal"))):
        ET.SubElement(root, tag).text = val
    sw, _ = switches(rs.inputs)
    root.append(sw)
    # J1 order in the shell: Button 1, Button 2, Button 3, Start, Coin. Riot
    # has three buttons (its Button 1 is in the EXTRA port), the others two.
    if rs.machine == "riot":
        ET.SubElement(root, "buttons", names="Button 1,Button 2,Button 3,Start,Coin",
                      default="A,B,X,Start,Select")
    else:
        ET.SubElement(root, "buttons", names="Button 1,Button 2,-,Start,Coin",
                      default="A,B,X,Start,Select")
    gid = ET.SubElement(root, "rom", index="1")
    ET.SubElement(gid, "part").text = f"{MACHINE_ID[rs.machine]:02X}"
    root.append(rom_element(rs, sets, fidx, fpos, crcs))
    ET.indent(root, "    ")
    safe = re.sub(r'[\\/:*?"<>|]', "-", title)
    if rs.parent:
        outdir = OUTDIR / "_alternatives" / ("_" + PARENT_GAME[rs.parent])
    else:
        outdir = OUTDIR
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / f"{safe}.mra"
    path.write_text(ET.tostring(root, encoding="unicode") + "\n")
    return path, len(fidx)


def main(argv):
    sets = parse_driver()
    todo = argv or list(sets)
    bad = 0
    for s in todo:
        path, n = make(s, sets)
        got = assemble(path, ROOT / "roms")
        want = (REGIONS / s / "sdram.bin").read_bytes()[:n]
        parts = sum(1 for _ in ET.parse(path).getroot().iter("part"))
        if got == want:
            print(f"OK   {s:11s} {path.relative_to(ROOT)}: stream {n:#x} bytes = sdram.bin, {parts} parts")
        else:
            m = min(len(got), len(want))
            first = next((i for i in range(m) if got[i] != want[i]), m)
            print(f"BAD  {s:11s} {path.name}: lengths {len(got):#x}/{len(want):#x}, first diff at {first:#x}")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
