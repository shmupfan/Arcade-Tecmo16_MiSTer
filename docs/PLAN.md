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
| Sprite engine and blender reference | jotego `jtcores/cores/gaiden/hdl` (`jtgaiden_obj.v`, `jtgaiden_objscan.v`, `jtgaiden_blender.v`, `jtgaiden_colmix.v`, `jtgaiden_priority.v`), GPL-3.0-or-later, examined at jtcores b672aca (2026-10-02) | **M1 decision: reference only, not vendored** (m1_findings 3): it needs jtframe's object drawer, delay lines and raster conventions, its priority table differs from MAME's tecmo16 mixer in one branch, and our renderer is checked against MAME directly. Its resolution of MAME's four `rand()` branches is the one the core uses (R6) |
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

### 4.1 Video (built in M1, `rtl/t16_video.sv`, details m1_findings)

Line renderer (as Dooyong and 1945k III): during line L-1 one pass fetches
the three tilemaps (17 + 17 + 33 tiles) and walks the 256-entry sprite list,
writing four double line buffers (bg, fg, text, sprites); scan-out mixes
them per pixel (spec 9) with one or two palette reads.

- **Two-frame sprite lag** (spec 8): `t16_snapram` MODE 2. At vblank start
  S2 <= S and S <= live sprite RAM; the renderer reads S2. The copy is
  copy-before-write, so it equals MAME's instantaneous copy even when Riot
  and Ginkun write sprite RAM in the first microseconds of vblank
  (m1_findings 4).
- **Tile RAM, palette, scroll and flip: read LIVE** (decision below). The
  `LATCH` parameter switches to a snapshot of all of them taken at the
  start of line `LATCH_LINE` (14), built and verified in M1 as well.

### 4.1.1 Decision: live reads (Lee, 2026-10-02)

The core reads tile RAM, scroll and palette live while the frame is drawn
(`LATCH = 0`, the default). This is the most plausible PCB behaviour for a
line-based video chip, unconfirmed: **R1 stays open until frame-by-frame
PCB footage of a mid-frame text-layer write** (Final Star Force changes its
text layer during the scan in most busy frames, m0_findings 5). MAME draws
each frame once at vblank start, so it shows such a write on every line of
the frame; the core shows the old contents above the write and the new
below. Every captured frame where the two differ is classified in
m1_findings 5; the core is believed to be the accurate side for those
frames. Neither a live renderer nor a latch reproduces MAME on those frames;
only a renderer one frame behind the CPU would, at the cost of a frame of
display lag on every frame, which no evidence supports.

### 4.2 Clocks (M1)

96 MHz system clock. Video: 6 MHz pixel enable (96 / 16), 384 clocks a line
(6,144 system clocks), V_TOTAL = 264 lines: MAME's TODO guess for the real
board (t16:20), 59.19 Hz, against MAME's own 59.17 Hz / 256 lines (R3). The
visible window is MAME's (256 x 224, lines 16-239, vblank from line 240);
sync positions are not in the driver (R3). M2: 68000 phases every 4 clocks
(12 MHz), Z80 and YM2151 every 24 (4 MHz), M6295 every 96 (1 MHz), all
fractional enables in `t16_sys` / `t16_snd`.

M2 gate raster (`m2` build, m2_findings 4): MAME's 59.17 Hz, 256 lines, a
pixel enable of 47336/781250 (384 pixel periods per MAME line, exactly
MAME's frame period on average) and IRQ5 held 96,000 clocks (MAME's
1000 us). The release raster is a decision for Lee (section 8 of
m2_findings): MAME's raster, or the 6 MHz 384 x 264 guess (the `t16_sys`
defaults), both unmeasured (R3, R9).

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

### 4.4 On-chip RAM (estimate, M1; Quartus figures come in M4)

Video, LIVE build: palette 4,096 x 16 (7 M10K), five 2,048-word tile RAMs
(20), sprite list live + two buffers + marks (14), four 512 x 16 line
buffers (4): about 45 M10K. The LATCH build adds a shadow and a mark RAM
per tile RAM and the palette: about 41 more. System (M2, as built): main
RAM 16 KB (8 M10K), one 32 KB work RAM block serving Final Star Force's 24 KB
and Riot/Ginkun's 4 KB (16), sound ROM 64 KB in block RAM (32; SDRAM is the
alternative in M4), sound RAM 4 KB (2): about 58 M10K. Total about 103 (LIVE)
of 553.

## 5. Milestones

### M0. ROM validation and MAME oracle bootstrap (DONE, see m0_findings.md)

Gate: all 7 sets pass CRC/SHA1/size against the table generated from the
driver; regions rebuilt byte-identical to MAME's own dumps; the Python
renderer pixel-exact against MAME on every captured frame (attract of all
three parents with dense windows, real gameplay for fstarfrc and riot,
flip screen for all three, 300 frames of each clone).

### M1. Video RTL parity (DONE, see m1_findings.md)

Verilator frame replay of every M0 capture through the video RTL, fed the
dumped tile RAM, sprite buffer, scroll, flip and palette; RTL vs MAME
pixel-exact. Synthetic scenes vs t16_render.py: every sprite size and flip
combination, x/y wrap, all priority and blend branches (including the four
`rand()` branches, rendered deterministically), tile codes at region ends,
both tilemap widths, flip screen. Mid-scan replay of every captured frame
with visible-scan writes, each difference from MAME classified. jtgaiden
reuse and the latching structure decided (4.1).

### M2. Full-system boot in Verilator (DONE, see m2_findings.md)

fx68k + T80 + memory map + IRQ5 (held through vblank, released by
0x150021) + sound latch + inputs. Boot fstarfrc from power-on through the
attract and gameplay captures, riot and ginkun through their attract
captures; compare frames and RAM with MAME. Final Star Force's IRQ count
per frame depends on the vblank length (R3): divergences from that are
expected and must be explained.

### M3. Sound (DONE, see m3_findings.md)

Five 3,600-frame runs (Final Star Force attract and gameplay, Riot attract
and gameplay, Ginkun attract) against MAME's sound event log and WAV: every
latch, YM2151 and M6295 write and every IRQ / NMI entry identical in content
on every frame, sound RAM never persistently different, level within 0.22 dB
below 3.5 kHz. Two fixes: YM2151 writes held until jt51's `cen_p1` (the busy
flag was almost never set; root cause of M2's one-tick sequencer offset), and
jt6295's busy flags follow the committed channel state (a stop could be
cancelled by the next start; Ginkun's fades were lost). Remaining timing
differences are the YM2151 timer phase (R15) and the M6295 stop latency
(R14).

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
| R1 | Does the board read tile RAM and palette live during the scan (games write them mid-frame), or latch them per frame as MAME's single render implies? The core reads them live (4.1.1); open until frame-by-frame PCB footage of a mid-frame text-layer write | spec 10.1, m0_findings 5, m1_findings 5 |
| R2 | Sprite lag on the PCB: two frames as MAME's vblank copy gives, or a sprite framebuffer (jtgaiden models one)? | spec 8, t16:335-340 |
| R3 | Real raster: MAME guesses 6 MHz, 384 x 264 (59.19 Hz, close to MAME's 59.17); vblank and IRQ5 hold length, which sets how many IRQ5s Final Star Force takes | spec 4, t16:17-20 |
| R4 | What 0x150021 and 0x150031 do (IRQ clear, ack, DMA trigger?) | t16:348-366 |
| R5 | What the TECMO-5 "MCU?" does, and whether anything reads it | t16:903 |
| R6 | Mixer behaviour in the branches MAME fills with random colours or marks as guesses; Riot exercises blending heavily. The core takes the branch below each `rand()` (jtgaiden's choice); no captured frame hits one | spec 9, mix:120-261, m1_findings 7 |
| R7 | Value read at 0x160000 (Final Star Force reads it at scene changes) | t16:384 |
| R8 | How the hardware selects the 32- or 64-column tilemap | t16:373-374 |
| R9 | Meaning of the ten video registers MAME ignores (0x160002-0x16001c, written at boot; values include 0x010, 0x0ef, 0x0df = lines 16, 239, 223): raster, window or sync settings? | m0_findings 3 |
| R10 | Sprites (8-pixel cells) the PCB can draw on one line: MAME has no limit; the core's line pass takes 664 cells with the pessimistic ROM model, the games use at most 146. Final Star Force's boot RAM test fills sprite RAM with 0xFFFF for one frame (2,048 cells a line), which the core cannot draw (m2_findings 6) | m1_findings 6 |
| R11 | Interrupt acknowledge timing on the board (fx68k's E-clock-synchronised autovector, kept, against MAME's): where IRQ5 lands in the code, hence the interrupted context saved on the stack and in Riot's task blocks | m2_findings 5 |
| R12 | What a YM2151 read at A0 = 0 (0xFC04) returns; the core returns 0xFF as MAME's ymfm | m2_findings 9 |
| R13 | What the unmapped I/O at 0x150060-0x150067 and 0x150080-0x1500fe and the video registers at 0x160020-0x16002e drive (all written by the games, ignored by MAME and the core) | m2_findings 7 |
| R14 | M6295 latency from a stop command to the status reading idle (jt6295: up to one channel slot, 134 us; MAME: at once) | m3_findings 4 |
| R15 | YM2151 timer phase against the CPUs after reset: jt51 steps timers per sample cycle (as Nuked-OPM), MAME counts from the write; a 12.5 us sound CPU phase on Final Star Force and Ginkun | m3_findings 3 |

## 7. Risks

- Blending branches MAME marks as guesses (R6) only show on Riot; the
  core follows MAME until PCB video says otherwise.
- R1: the default build reads live (4.1.1). If PCB footage shows a per-frame
  latch, `LATCH = 1` is built and verified already (the latch line may need
  moving to what the footage shows).
- Compile PC instability (memory note `compile_pc_instability.md`): use
  the E-core-only build task; treat a crashed fit as untrusted.
