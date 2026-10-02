# Tecmo 16 MiSTer Core - Plan

Target: one MiSTer core (`Arcade-Tecmo16` working name) running every set
of MAME's `tecmo/tecmo16.cpp`: Final Star Force (fstarfrc, fstarfrcj,
fstarfrcja, fstarfrcw), Riot (riot, riotw) and Ganbare Ginkun (ginkun).
Spec: `docs/tecmo16_system_spec.md`. Method and tooling follow the Dooyong
and 1945k III cores (`../dooyong-mister`, `../1945kiii-mister`): MAME 0.288
is the oracle, a Python reference renderer is checked pixel-exact against
it, the RTL is checked against both in Verilator, then the MiSTer shell and
Quartus.

Accuracy rule: where MAME is unsure (spec 13) the core follows MAME for
parity and the item is logged as a research question; nothing is invented.
If PCB evidence later contradicts MAME, real hardware wins and the MAME
difference is logged.

## 1. Scope

- One RBF, game selected by a game ID byte in the MRA. The three machine
  configs differ in a handful of muxes: tile RAM map and tilemap width
  (32 x 32 for Final Star Force, 64 x 32 for Riot and Ginkun), text-layer y
  offset (spec 7), sprite y-size field (bits 3-2, Riot bits 1-0), Riot's
  EXTRA fire buttons and 0x124000 RAM, DSW layouts. Rotation from the MRA
  (ROT90 for Final Star Force, ROT0 for the others).
- 68000 + Z80 + YM2151 + M6295; three tilemaps, one 256-entry sprite list,
  a blending mixer, a 4,096-entry palette.

## 2. Reuse

| Block | Source | Notes |
|---|---|---|
| fx68k (68000, cycle-exact) | `../dooyong-mister/rtl/vendor/fx68k` (from Hyper Duel), with PROVENANCE.md | copy with provenance, no edits |
| T80 (Z80) | `../dooyong-mister/rtl/vendor/t80` (jtcores 0b197ca), with PROVENANCE.md | includes the IX/IY power-on patch |
| jt51, jt6295 | `../dooyong-mister/rtl/vendor/` (SOUND_PROVENANCE.md) | the sound board is the same Z80 + YM2151 + M6295 shape as Dooyong's Flying Tiger: start from `dy_snd.sv` |
| Sprite engine and blender reference | jotego `jtcores/cores/gaiden/hdl` (`jtgaiden_obj.v`, `jtgaiden_objscan.v`, `jtgaiden_blender.v`, `jtgaiden_colmix.v`, `jtgaiden_priority.v`), GPL-3.0-or-later, jtcores 881576a (2026-08-25) | same Tecmo sprite chip and mixer family as MAME's gaiden.cpp; `jtgaiden_blender.v` is the saturating 4-bit add that equals MAME's `sum_colors` after 4-to-8-bit expansion. jtframe-dependent: port or use as a reference, decided in M1 |
| SDRAM controller, MiSTer shell, ioctl download | `../dooyong-mister/rtl/dy_sdram.sv`, `Arcade-Dooyong.sv`, `dy_board.sv` | rename, re-parameterise the SDRAM layout (4.3) |
| MRA generator, deploy script | `../dooyong-mister/tools/make_mra.py`, `deploy_mister.sh` | |
| Oracle, renderer, comparison | ported in M0 (`sim/mame/t16_oracle.lua`, `sim/oracle/t16_render.py`, `compare_frames.py`) | |

New RTL: three tilemap passes, sprite engine (or jtgaiden port), mixer,
system glue (memory map, IRQ5, sound latch, inputs).

## 3. Variant order

1. fstarfrc (parent, the shooter): M1 to M4.
2. fstarfrcj, fstarfrcja, fstarfrcw: same config, MRAs once fstarfrc works,
   each with an M2 boot comparison.
3. riot, riotw: 64-column maps, blending in heavy use, IRQ ack via
   0x150021, EXTRA buttons.
4. ginkun.

## 4. Architecture

### 4.1 Video

Line renderer (as Dooyong and 1945k III): per line, fetch the three
tilemaps into line buffers, walk the 256-entry sprite list and draw the
hits into a sprite line buffer (value = colour/priority/blend bits + pen,
spec 8), then mix per pixel (spec 9).

Sprite load per line, worst case in all M0 captures: 24 sprites and 146
8-pixel columns on one line (Final Star Force World attract); Riot with
flip screen showed 128 sprites crossing one line, all 8x8. At an assumed
96 MHz system clock and MAME's 256-line frame, one line is 6,338 clocks
(6,144 for the 6 MHz / 384-clock guess in spec 4): enough for a list walk
and 146 column fetches of 32 bits from SDRAM.

Two parity points the RTL must reproduce:

- **Two-frame sprite lag** (spec 8): at vblank start, render from the
  buffer, then copy live sprite RAM into the buffer. In RTL: the line
  renderer for frame N reads a buffer B1 holding the live RAM of vblank
  N-2; at vblank start copy B0 -> B1 and live -> B0 (two 4 KB buffers, or
  one buffer plus drawing frame N's list into a framebuffer, which is what
  jtgaiden's `frmbuf_en` option does).
- **Frame-latched tile RAM and palette** (spec 10.1): MAME renders the whole
  frame from the state at vblank start. Games write tile RAM during the
  visible scan: Final Star Force changes text RAM values mid-scan in 362 of
  501 frames (lines 16-63), bg RAM in 7 of 501; Riot and Ginkun bg/fg/text
  RAM in a few frames per 500 (m0_findings 5). A renderer reading live RAM
  would differ from MAME in those frames. For parity the RTL keeps a copy
  of tile RAM, palette and scroll latched at vblank start (about 20 KB
  for Riot/Ginkun tile RAM + 8 KB palette). Whether the PCB reads live is
  R1; the M1 decision is MAME parity by default, as in Dooyong (R12) and
  1945k III (R3).

### 4.2 Clocks (proposal)

96 MHz system clock; 68000 enable at 12 MHz (/8); Z80 and YM2151 at 4 MHz
(/24); OKI at 1 MHz from an 8 MHz enable (/12 then /8, or a direct /96
enable to the jt6295 cen); pixel enable 6 MHz (/16) if the PCB timing
guess (spec 4) is adopted, else MAME's 59.17 Hz / 256-line raster
(15.15 kHz line, 6,338 clocks per line), which needs a fractional enable.
Choice made in M1 with R3.

### 4.3 SDRAM layout (fixed in tools/build_regions.py)

| Region | Base | Capacity |
|---|---|---|
| maincpu | 0x000000 | 512 KB |
| bgtiles | 0x080000 | 1 MB |
| sprites | 0x180000 | 1 MB |
| fgtiles | 0x280000 | 128 KB |
| audiocpu | 0x2a0000 | 64 KB |
| oki | 0x2b0000 | 256 KB |
| end | 0x2f0000 | about 3 MB of 32 MB |

audiocpu, fgtiles and oki are small enough for M10K if SDRAM ports run
short (decided in M4).

### 4.4 On-chip RAM (estimate)

Main RAM 16 KB, Final Star Force work RAM 24 KB (0x122000-0x127fff), Riot
extra 4 KB, palette 8 KB, sprite RAM 4 KB + two 4 KB buffers, tile RAM up
to 20 KB plus a 20 KB latched copy, Z80 RAM 3 KB, line buffers: about
110 KB, roughly 90 M10K of 553.

## 5. Milestones

### M0. ROM validation and MAME oracle bootstrap (DONE, see m0_findings.md)

Gate: all 7 sets pass CRC/SHA1/size against the table generated from the
driver; regions rebuilt byte-identical to MAME's own dumps; the Python
renderer pixel-exact against MAME on every captured frame (attract of all
three parents with dense windows, real gameplay for fstarfrc and riot,
flip screen for all three, 300 frames of each clone).

### M1. Video RTL parity

Verilator frame replay of every M0 capture through the video RTL, fed the
dumped tile RAM, sprite buffer, scroll, flip and palette; RTL vs MAME
pixel-exact. Synthetic scenes vs t16_render.py: every sprite size and flip
combination, x/y wrap, all priority and blend branches (including the four
`rand()` branches, which the RTL must render deterministically and log),
tile codes at region ends, both tilemap widths, flip screen. Decide the
jtgaiden reuse and the latching structure (4.1). Gate: 100% of frames.

### M2. Full-system boot in Verilator

fx68k + T80 + memory map + IRQ5 (held through vblank, released by
0x150021) + sound latch + inputs. Boot fstarfrc from power-on through the
attract and gameplay captures, riot and ginkun through their attract
captures; compare frames and RAM with MAME. Final Star Force's IRQ count
per frame depends on the vblank length (R3): divergences from that are
expected and must be explained.

### M3. Sound

T80 + jt51 + jt6295 from the Dooyong sound path; YM2151 stereo, OKI
routed to both sides (spec 2). Compare register and command streams with
MAME and the level with MAME WAVs.

### M4. MiSTer shell, SDRAM, Quartus

Board harness (MRA stream into the SDRAM model), MRAs for all 7 sets (DSW
defaults per spec 11), rotation, inputs, Quartus build on the compile PC
(E-core schtasks pattern), timing closed on every clock. First RBF on the
MiSTer.

### M5. Hardware QA and release

All seven sets on hardware, DIPs, long play, sound by ear; release into
the shmupfan Distribution database.

## 6. Research questions needing PCB evidence

| # | Question | Source |
|---|---|---|
| R1 | Does the board read tile RAM and palette live during the scan (games write them mid-frame), or latch them per frame as MAME's single render implies? | spec 10.1, m0_findings 5 |
| R2 | Sprite lag on the PCB: two frames as MAME's vblank copy gives, or a sprite framebuffer (jtgaiden models one)? | spec 8, t16:335-340 |
| R3 | Real raster: MAME guesses 6 MHz, 384 x 264 (59.19 Hz, close to MAME's 59.17); vblank and IRQ5 hold length, which sets how many IRQ5s Final Star Force takes | spec 4, t16:17-20 |
| R4 | What 0x150021 and 0x150031 do (IRQ clear, ack, DMA trigger?) | t16:348-366 |
| R5 | What the TECMO-5 "MCU?" does, and whether anything reads it | t16:903 |
| R6 | Mixer behaviour in the branches MAME fills with random colours or marks as guesses; Riot exercises blending heavily | spec 9, mix:120-261 |
| R7 | Value read at 0x160000 (Final Star Force reads it at scene changes) | t16:384 |
| R8 | How the hardware selects the 32- or 64-column tilemap | t16:373-374 |

## 7. Risks

- Blending branches MAME marks as guesses (R6) only show on Riot; the
  core follows MAME until PCB video says otherwise.
- The latched-copy RAM cost (4.1) is small; if R1 shows live reads, the
  copy is dropped and the oracle comparison becomes per-line.
- Compile PC instability (memory note `compile_pc_instability.md`): use
  the E-core-only build task; treat a crashed fit as untrusted.
