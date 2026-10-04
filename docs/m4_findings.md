# M4 findings: MiSTer shell, SDRAM, MRA, Quartus (prepared in parallel with M3)

Date: 2026-10-03. Status: prepared, not built (no Quartus compile has run).
Written alongside M3, which owns rtl/t16_snd.sv, sim/m3*, docs/m3_findings.md
and sim/Makefile; nothing here edits those files. sim/m4.mk holds the M4
targets until sim/Makefile includes it. Template: the 1945k III core's M4
(same Quartus 17.0 project settings, framework, PLL and SDRAM protocol) and
Dooyong's.

## 1. Names (proposal)

| Item | Value |
|---|---|
| Repository | Arcade-Tecmo16_MiSTer |
| Quartus project / revision | Arcade-Tecmo16 |
| Released core | releases/Arcade-Tecmo16_YYYYMMDD.rbf (MiSTer-devel strips "Arcade-": Tecmo16_YYYYMMDD.rbf) |
| MRA `<rbf>` | tecmo16 |
| OSD title | Tecmo16 |

MAME's driver is tecmo16.cpp and the hardware is known as "Tecmo 16-bit";
the three games (Final Star Force, Riot, Ganbare Ginkun) have no shared
title, so the board name is the one players will find.

## 2. Files

| File | Content |
|---|---|
| `Arcade-Tecmo16.sv` | Template_MiSTer `emu`: hps_io, MAME default keyboard (P1 arrows, LCtrl/LAlt/Space, 1, 5; P2 R/F/D/G, A/S/Q, 2, 6; P toggles pause), pause when the OSD is open (O6, default on), inputs in MAME's P1_P2 / EXTRA layout per game (Riot's Button 1 is in EXTRA, its Buttons 2-3 in P1_P2), t16_board at 96 MHz, toggle hand-off of each pixel to the 48 MHz video clock, arcade_video 256 wide at 48 MHz, screen_rotate for Final Star Force (ROT90: clockwise), 4:3 / rotated 3:4, stereo audio |
| `rtl/t16_board.sv` | t16_sys + t16_sdram + ioctl: index 0 ROM stream (= sdram.bin), index 1 machine byte (0 Final Star Force, 1 Riot, 2 Ginkun), index 254 DIP bytes (byte 0 = DSW1, byte 1 = DSW2, each in the low half of its 16-bit port); the audiocpu bytes of the stream are also written into t16_sys's sound ROM; core in reset during downloads and until the SDRAM is ready |
| `rtl/t16_sdram.sv` | bank-per-region controller with registered request paths (section 3) |
| `Arcade-Tecmo16.qpf/.qsf/.sdc/.srf`, `files.qip`, `pll.v`, `pll/`, `sys/`, `build_id.v`, `clean.bat` | Quartus 17.0 project; qsf, sys/, PLL (96, 96 at -90 degrees, 48 MHz) copied from 1945k III unchanged except names; files.qip lists T80 as VHDL (as Dooyong), jt51 via its qip, jt6295, fx68k; sdc multicycles 2 inside fx68k, the sound T80, jt51 and jt6295, false paths on the machine byte and DIPs |
| `tools/make_mra.py` | MRAs for all 7 sets, DIPs parsed from the driver (section 4) |
| `tools/pc_build.sh` | compile PC: push / task / run / status / fetch (section 6) |
| `sim/m4/tb_sdram.sv`, `tb_sdram.cpp`, `sdram_model.sv` | controller test (section 3; the model is 1945k III's, unchanged) |
| `sim/m4/tb_board.sv`, `tb_board.cpp` | board harness (section 5) |
| `sim/m4/lint_stubs.sv` | framework stubs (from Dooyong / 1945k III) to lint the shell under Verilator |
| `releases/*.mra`, `releases/_alternatives/` | the generated MRAs |

## 3. SDRAM controller

### 3.1 Layout and banks

The logical layout is PLAN 4.3 (the MRA stream). Every region boundary is a
multiple of 64 KB, so the mapping rebases only the 6-bit segment number:

| Bank | Regions (logical) | Bank offset |
|---|---|---|
| 0 | maincpu 0x000000-0x07FFFF | 0 |
| 1 | bgtiles 0x080000-0x17FFFF, fgtiles 0x280000-0x29FFFF | 0, 0x100000 |
| 2 | sprites 0x180000-0x27FFFF | 0 |
| 3 | audiocpu 0x2A0000-0x2AFFFF, oki 0x2B0000-0x2EFFFF | 0, 0x10000 |

The program ROM (512 KB) is too large for block RAM beside the video, so it
is fetched from SDRAM. The 68000 runs without wait states on the real board
(MAME's memory model; m2_findings 3): t16_sys asserts DTACK at once and keeps
loading the word until ok, which must arrive within 17 clocks of the request
(PROM_LIMIT; 18 breaks the program, `make m2-promlat`). With the program alone
in bank 0, a fetch never waits for another client's row.

### 3.2 Timing from the start (lesson of 1945k III compile 1)

1945k III's first Quartus build failed 96 MHz by about 1 ns: the controller
arbitrated and drove the SDRAM_A mux in the same clock, straight from the
68000 address bus, the OKI address and a FIFO RAM output. This controller
registers every path before it can reach the command decode:

- CPU: request, address and the hit test registered (c_req_q, c_addr_q,
  c_hit_q); the ACT is decoded from those (the same structure as the 1945k
  III controller at the time of writing).
- OKI: the held address and its mapped bank word are registered (k_addr_q,
  k_word_q); the "wants a read" decision compares registers and only fires
  once the registered address equals the live one, so the graphics grant
  (o_gfx_gnt) depends on registers only.
- Download: the ioctl byte, address and the even/odd pairing are registered,
  and the FIFO stores the already mapped {bank, word}, so its read side feeds
  the pending slot with no arithmetic.
- Graphics: the 4-byte address is mapped (a 6-bit compare and subtract) as
  it enters the pending-slot register.
- The next job is chosen one clock ahead into the pending slot; SDRAM_A/BA
  are driven from pend_word, c_addr_q or o_word registers; only cmd waits for
  the start decision.

Whether this closes 96 MHz is only known after the first compile.

### 3.3 Results

`make -f m4.mk m4-sdram` (fstarfrc image downloaded through the byte port,
then 4,000,000 clocks of all clients at once; the model stops on any SDRAM
protocol or timing violation):

| Client | Result |
|---|---|
| CPU (68000 at 12 MHz: bus cycles at least 32 clocks apart, ~70% program reads, jumps, repeats, STOP-like gaps) | 81,947 fetches, 0 errors; latency 9 clocks (73,933), 10 (4,764), 1 for a repeat of the last word (3,250); worst 10 of the 17 allowed |
| Graphics (a request every clock, random reads in bg, sprite and fg tiles) | 507,833 reads, one per 7.88 clocks, 0 errors |
| OKI (new byte address every 40-400 clocks) | 18,190 reads checked, 0 errors |
| Refresh | 0 forced (every refresh fell in the window after a fetch while the CPU ran) |

`make -f m4.mk m4-sdram-all` (1,000,000 clocks per set): PASS on all 7 sets,
worst CPU latency 10 clocks. (The download word counter is 16 bits and wraps:
1,540,096 words mod 65,536 = 32,768 as printed.)

Graphics bandwidth: one 32-bit read per 7.88 clocks under full pressure; the
M1 gate used a pessimistic model of one per 8 clocks (worst game line 1,988
of 6,144 clocks at that rate, m1_findings).

## 4. MRAs

`tools/make_mra.py` (adapted from 1945k III): for each set the ROM stream is
derived from the driver's ROM_START loads, encoded as parts and interleaves,
then replayed with Main_MiSTer's mra_loader rules from the zips and compared
with sim/build/regions/<set>/sdram.bin byte for byte (0x2F0000 bytes, 11
parts each). Result: 7/7 OK.

| Set | File | Machine | Rotation |
|---|---|---|---|
| fstarfrc | releases/Final Star Force (US).mra | 0 | vertical (cw) |
| fstarfrcj, fstarfrcja, fstarfrcw | releases/_alternatives/_Final Star Force/ | 0 | vertical (cw) |
| riot | releases/Riot (NMK).mra | 1 | horizontal |
| riotw | releases/_alternatives/_Riot/Riot (Woong Bi).mra | 1 | horizontal |
| ginkun | releases/Ganbare Ginkun.mra | 2 | horizontal |

DIP switches are parsed from INPUT_PORTS DSW1 and DSW2, never typed: MRA
bits 0-7 = DSW1, 8-15 = DSW2 (t16_board puts byte 0 on DSW1, byte 1 on
DSW2). Defaults are MAME's: FF,FF on Final Star Force and Ginkun, FF,FC on
Riot (Lives default 0x00, the value the M2 gate ran with). Two parser fixes
against the 1945k III version: two 8-bit ports instead of one 16-bit port,
and MAME labels containing commas (Final Star Force "200000,1000000" bonus
lives) get "/" since MRA ids are comma separated. Final Star Force's set
name "(World?)" becomes "(World-)" in the file name (the 1945k III rule for
characters a FAT file name cannot hold); the <name> element keeps MAME's.

Buttons (J1 order Button 1, Button 2, Button 3, Start, Coin): Riot uses all
three, the others two (Button 3 is "-").

## 5. Board harness

`sim/m4/tb_board.cpp` was generated once from the committed M2 harness
(m2/tb_sys.cpp at 4eaadb7) and changed only where the board replaces the C++
memory models: machine byte, DIPs and the ROM stream go through t16_board's
ioctl port (honouring ioctl_wait) into t16_sdram and the cycle-checked SDRAM
model; the board copies the audiocpu bytes into the sound ROM; hierarchy
prefix tb_board.u_board.u_sys. Outputs, formats, frame numbering, input
replay and plusargs are M2's, so `m2/compare.py` checks a board run against
MAME exactly as an M2 run. tb_board uses MAME's raster by default (the M2
gate configuration).

`make -f m4.mk m4-build` builds it; `make -f m4.mk m4-smoke` boots each
parent for 300 frames (images at frames 100, 200, 300). Smoke results:


| Set | Download | Vblanks | I/O writes to vblank 300 vs the M2 gate run | Files at frame 200 vs M2 | Counters |
|---|---|---|---|---|---|
| fstarfrc | 3,080,192 bytes, 15.6M clocks | 301 | 3,781, identical byte for byte (beam positions included) | 15 of 15 identical (image, palette, tile RAMs, sprite RAM and both buffers, main/work/sound RAM, scroll registers, write log) | promlate 0, SDRAM CPU worst 10 clocks, 0 forced refreshes; 49 overrun lines = the boot RAM-test frame 16 that M2 documents (R10) |
| riot | same | 301 | 723, identical | 15 of 15 identical | promlate 0, worst 10, 0 forced, 0 overruns |
| ginkun | same | 301 | 3,004, identical | 15 of 15 identical | promlate 0, worst 10, 0 forced, 0 overruns |

The worst renderer line is longer through the SDRAM (fstarfrc 22,210 clocks
on the boot frame against M2's 17,204; Riot 2,399 against 1,844) because
graphics reads now queue behind the CPU and OKI; no game frame overran.
(M2's comparison frames at 100 and 300 are not in its capture list; frame
200 is.)

The full M4 gate (board boots over the M2 capture ranges, compared with
m2/compare.py and against the M2 runs byte for byte) is the next step once
M3 lands.

## 6. Compile PC

`C:\t16_build` exists on the compile PC, with the build
inputs pushed once (`tools/pc_build.sh push`, `._` files excluded) and
`runcompile.cmd`:

    cd /d C:\t16_build
    start /B /WAIT /AFFINITY FFFF0000 C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile Arcade-Tecmo16 >> compile.log 2>&1

Scheduled task `t16compile` is created (status Ready, far-future trigger, so
it only runs on `schtasks /run`), NOT run: the 1945k III timing-closure work
owns the PC's compiles at the time of writing. Before the first compile,
push again (the pushed rtl/ includes M3's work in progress), then
`tools/pc_build.sh run`, `status`, `fetch`. Never run quartus_sh as a child
of ssh (Windows OpenSSH kills the process tree when the session ends).

## 7. Decisions pending and open items

- Raster (R3): the shell builds MAME's 59.17 Hz / 256-line raster
  (`RASTER_MAME = 1` in Arcade-Tecmo16.sv, the M2 gate configuration);
  setting it to 0 builds the 6 MHz 384 x 264 alternative. Lee's decision.
- Flip: the games' own Flip Screen DIP (the game writes the flip register);
  no OSD flip option (screen_rotate's flip applies only to the rotated
  frame buffer).
- Video handoff: pixels are at least 16 core clocks apart (5.82 MHz at MAME's
  raster), as the toggle scheme needs.
- `builds/` and `sim/build/m4` outputs should be gitignored when this is
  committed (.gitignore not edited here).
- Not yet done: Quartus compile and timing closure, the full M4 board gate,
  hardware test.

## 8. Timing closure (2026-10-03)

Compile 1 (M4 prep RTL) fitted at 33% ALM / 42% RAM blocks / 38 DSP but the
96 MHz core clock failed setup: slack -0.545 ns, TNS -4.212 (hold positive
everywhere). Path report: `tools/sta_paths.tcl`, run on the PC by the
scheduled task `t16sta` (`C:\t16_build\runsta.cmd`, E-core affinity),
writing `paths_setup.txt` / `paths_worst.txt` (400 worst setup paths to the
core clock).

**Cause.** All 400 failing paths were one cone in `t16_video`: the sprite
list snapshot RAM read port (`u_spr`, `g_two.u_s2`, unregistered M10K output)
into the walker registers `w_e` (293 paths), `w_ln` (62) and `w_row` (45).
The W_HIT state did, in one clock: word 3 from the RAM, sign extension, the
flip transform (`256 - h - y`, wrap compare, mux), `line - y_pos`, the hit
compare and the row/line arithmetic (worst path 9.72 ns of logic and routing
from the RAM's clock-to-out).

**Fix (behaviour-neutral).** The walker gets one more state. W_HIT now only
registers `y_pos` (the sign-extended, flip-transformed y of word 3) into
`w_ypos`; the new W_HIT2 does the hit test (`y_d = line - w_ypos`) and the
row/line arithmetic. W_HIT2 presents the same word-1 address as W_HIT, so
word 1 still arrives in W_A4. The walker spends one more clock per enabled
entry; `r_line` and `r_flip` are constant for the whole pass. No SDRAM,
board or shell change was needed; no multicycle constraints were added.

**Verification** (RTL vs the pre-change RTL and vs MAME):

| Check | Result |
|---|---|
| M1 replay, LIVE build, every M0 capture | 10,502 / 10,502 exact (as M1) |
| M1 replay, LATCH build | 10,502 / 10,502 exact |
| M1 synthetic scenes | 210 / 210 |
| M1 mid-scan classification | LIVE 4,157 exact + 159 explained, LATCH differs on 385 (identical to M1) |
| M1 capacity | unchanged: 256 sprites (8 and 16 px), 166 (32 px), 83 (64 px) on one line, 664 cells; worst game line 1,988 of 6,144 clocks |
| M2 system boots before/after, 600 frames, fstarfrc, riot, ginkun (committed t16_snd/tb_sys, captures at every vblank) | 9,003 files each, all byte-identical, I/O logs included (9,540 / 1,323 / 6,004 writes); gate counters identical |
| M4 SDRAM test, every set | PASS, worst CPU latency 10 clocks (limit 17, t16_sys PROM_LIMIT) |
| M4 board smoke boots (300 frames, ioctl + SDRAM model) | promlate 0, sdram_cpu_maxlat 10, ref_forced 0; fstarfrc's 49 overruns are the known frame-16 boot sprite RAM fill (m2_findings) |
| Lint | our RTL clean; warnings only in vendored fx68k/jt6295/T80; shell lint clean |

**Compile 2** (2026-10-03 06:22, sources = this RTL with the committed
`t16_snd.sv` from 4eaadb7, M3 work in progress excluded): every clock
non-negative.

| Clock | Setup | Hold | Recovery | Removal |
|---|---|---|---|---|
| core 96 MHz (`emu pll general[0]`) | +0.689 ns | +0.230 ns | +6.387 ns | +0.680 ns |
| `emu pll general[2]` (48 MHz video) | +3.660 ns | +0.248 ns | | |
| HDMI | +0.257 ns | +0.193 ns | +3.615 ns | +0.656 ns |
| all others | positive | positive | positive | positive |

Fit: 13,819 / 41,910 ALM (33%), 235 / 553 RAM blocks (42%), 1,787,312 block
memory bits (32%), 38 / 112 DSP. RBF: `builds/20261003_0622_Arcade-Tecmo16.rbf`,
md5 `6e8d3aee2601ac0a21ddd2516758c5c3` (not hardware tested). Note: this RBF
has the committed M2 sound RTL, not M3's fixes; rebuild after M3 lands.

## 9. Video sync during the ROM download, HDMI options, Rotate option (2026-10-04)

The board held the core in reset through the ROM download and SDRAM
init, and that reset also stopped the pixel enable and raster counters,
so there was no sync for the length of the download (the Dooyong core
showed a green no-signal screen there). With FREE_TIMING (t16_sys /
t16_video parameter, set to 1 by t16_board) the raster runs from the PLL
lock with black RGB; once a frame the pixel enable that would start the
power-on line (V_VBL) reloads the counters instead, and the core leaves
reset on the clock after that reload, so the game starts exactly as from
a plain reset release.

Board A/B (base e4a3140 vs the fix, fstarfrc 601 frames): 945 / 945
common capture files identical; 11 vsyncs and 0 lit pixels before the
core runs (base: 1 vsync). The base also writes 000001.rgb, which the
fix run skips: with sync running before the release, the harness's first
"frame" spans part of the reset period and is not a full 256 x 224 frame,
so the harness does not dump it (frame 1's RAM dumps and write log are
identical). Earlier A/B on the pre-variant-e base: fstarfrc and ginkun
945 / 945 each.

Shell: OSD Rotate CW (MAME ROT90) / CCW for Final Star Force (frame
buffer only; on a CRT use the Flip Screen DIP), Scale options, and a
216-line crop with offset for unrotated 224-line output, through
video_freak. The shell lints clean with the framework stubs.

Build builds/20261004_Arcade-Tecmo16.rbf, md5
ea8e2e65a98e991cf8510ce646e156ff: all clocks non-negative (core setup
+0.757 / hold +0.151 ns, HDMI setup +0.434 / hold +0.249 ns), 34% ALMs,
42% RAM blocks. Not released; not tested on hardware.
