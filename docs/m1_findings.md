# M1 findings: video RTL parity

Date: 2026-10-02. RTL `rtl/t16_video.sv` (+ `t16_snapram.sv`, `t16_dpram.sv`,
`t16_fifo.sv`), Verilator 5.050, against the M0 captures (MAME 0.288) and
`sim/oracle/t16_render.py`. Reproduce with `cd sim && make m1` (build,
snapshot RAM test, verify, synthetic scenes, mid-scan replay) after
`make m1-vislog` (the VISLOG rerun of the captures, section 5).

## 1. Gate verdict: PASS

| Check | Result |
|---|---|
| `make m1-verify`: RTL vs MAME's snapshot on every M0 capture frame, all 7 sets | **10,502 / 10,502 frames pixel-exact**, also equal to `t16_render.py` on every frame; 0 line overruns; 0 snapshot-engine errors |
| `make m1-synth`: 210 synthetic scenes (3 machines x flip off/on) vs `t16_render.py` | **210 / 210 exact**, 0 overruns; all 31 mixer branches hit (`build/m1/mix_coverage_scenes.txt`) |
| `make m1-midscan`: 4,316 captured frames with visible-scan writes, replayed with the writes at their beam position | **0 unexplained**: 4,157 exact, 159 explained (section 5) |
| `make m1-snapram`: sprite list copy-before-write | 80 rounds, 38,360 CPU writes during copies, 0 mismatches; a plain write-through mutant fails (312 mismatches in 5 rounds) |
| `make m1-verify-latch`: LATCH build (`-GLATCH=1`), same replay | **10,502 / 10,502 exact**, 0 overruns, 0 snapshot errors; on frames with visible-scan writes see section 5.4 |
| Verilator `-Wall` | clean (suppressed classes as in the 1945k III core: UNUSEDSIGNAL, UNUSEDPARAM, WIDTHEXPAND, WIDTHTRUNC) |

Per capture (`build/m1/verify.txt`):

| Run | Frames exact | Worst line pass (clocks of 6,144) |
|---|---|---|
| fs_attract | 2,025 / 2,025 | 1,892 |
| fs_play | 1,326 / 1,326 | 1,588 |
| riot_attract | 2,025 / 2,025 | 1,428 |
| riot_play | 1,001 / 1,001 | 1,273 |
| ginkun_attract | 2,025 / 2,025 | 1,345 |
| fs_flip, riot_flip, ginkun_flip | 300 / 300 each | 1,572 / 1,844 / 1,332 |
| clone_fstarfrcj, fstarfrcja, fstarfrcw, riotw | 300 / 300 each | 1,604 / 1,604 / 1,988 / 1,332 |

## 2. Architecture

- **Clocks and raster**: 96 MHz system clock, 6 MHz pixel enable (1 in
  16), 384 pixels per line (6,144 clocks), `V_TOTAL` = 264 lines (MAME's
  TODO guess for the board, t16:20; 59.19 Hz). The visible window is MAME's:
  256 x 224 at lines 16-239, vblank from line 240 (t16:681-682). Sync
  positions are not in the driver: hsync pixels 304-335, vsync lines
  248-250, logged under R3. MAME itself runs 256 lines at 59.17 Hz; the
  difference does not touch any pixel (it matters for IRQ5 in M2).
- **Line renderer**: the pass for line L runs during line L-1: bg and fg
  (17 tiles x 2 words each, 16 x 16 tiles of 2 x 2 packed 8 x 8 cells),
  text (33 tiles x 1 word), and a sprite walker over the 256-entry list
  (5 words read per enabled entry, 2 clocks per disabled one) that queues
  the entries crossing the line; one ROM word per 8 x 8 cell row. Words
  land in four double line buffers (bg 8 bits, fg 9, text 8, sprites 11).
  Scan-out mixes per pixel with one or two palette reads.
- **ROM port**: one port for all graphics, checked with the Dooyong M1
  pessimistic model (one 32-bit read accepted per 8 clocks, data 9 clocks
  later). SDRAM layout as PLAN 4.3.
- **RAMs** (`t16_snapram`): palette 4,096 words, text, fg codes, fg
  colours, bg codes, bg colours 2,048 words each (Final Star Force maps
  1,024 words of each tile RAM, spec 3), sprite list 2,048 words. MODE 0
  (plain dual port) for tile RAM and palette in the default build, MODE 1
  (snapshot) in the LATCH build, MODE 2 (two-stage) for the sprite list.

## 3. jtgaiden reuse decision: reference only

Examined jotego's jtgaiden at jtcores b672aca (GPL-3.0-or-later,
`reference/jtgaiden/PROVENANCE.md`): `jtgaiden_obj.v`, `jtgaiden_objscan.v`,
`jtgaiden_colmix.v`, `jtgaiden_priority.v`, `jtgaiden_blender.v`.

- The sprite path (`jtgaiden_obj`) is built on jtframe modules
  (`jtframe_objdraw`, `jtframe_sh`, `jtframe_8x8x4_packed_msb`) and
  jtframe's raster conventions (`hdump`, `vrender`, a 9-pixel output delay,
  a sprite y scroll and a frame-buffer y offset of -2 that gaiden needs and
  tecmo16 does not). Porting it means importing and re-verifying jtframe
  pieces to reach what a pass written directly from MAME's sources reaches.
- `jtgaiden_priority` matches MAME's tecmo16 mixer table except one branch:
  a blended sprite above bg over a blended fg pixel. MAME sums the bg blend
  palette with the sprite blend source (mix:157-162, marked "WRONG??"); the
  jtgaiden table blends fg with the sprite. Section 7 shows the games use
  that branch heavily (240,646 pixels in the captures), so the core follows
  MAME there (accuracy rule: MAME until PCB evidence).
- `jtgaiden_blender` (per-channel saturating 4-bit add) equals MAME's
  `sum_colors` after 4-to-8-bit expansion; the core uses the same 12-line
  arithmetic, written fresh.
- jtgaiden resolves MAME's four `rand()` branches by dropping the blend;
  the core does the same (section 7).

So no jtgaiden file is vendored; the renderer is new RTL from the MAME
sources, checked against MAME frame by frame.

## 4. Sprite list buffer: two-frame lag, copy-before-write

MAME (t16:330-341): at each vblank start the sprite bitmap is drawn from
the buffered list, then the live RAM is copied into the buffer, so frame N
shows the live RAM of vblank N-2 (confirmed in M0). The core: `t16_snapram`
MODE 2 holds the buffer S and a second copy S2; at the start of line 240,
S2 <= S and S <= live, and the renderer reads S2 during frame N. The frame
replay feeds the dumped buffer and copies twice, so all 10,502 frames check
the lag model.

MAME's copy is instantaneous; the engine walks 2,048 words in 4,096 clocks
(43 us). The heavy-log runs show games write sprite RAM within the first
84 pixels of vblank (after MAME's copy): Riot 17 writes and Ginkun 12 in 500
frames each (Final Star Force none). A plain sequential copy would pick some
of those up a frame early. The engine is copy-before-write: a CPU write that
lands during the walk is held, its address is copied first (if not done
yet), then the write commits, so the buffer equals the RAM at the snap clock
exactly. A 1-bit mark per address against a per-snapshot epoch records
which addresses are done (every snapshot visits every address, which avoids
the 1-bit generation failure seen in the Dooyong core). Verified by
`make m1-snapram` (section 1); whether the PCB copies instantly, by DMA
during vblank, or keeps a frame buffer is R2.

## 5. Writes during the visible scan (R1)

### 5.1 Decision (Lee, 2026-10-02)

Tile RAM, scroll, flip and palette are read **live** while the frame is
drawn (`LATCH = 0`, default): the most plausible PCB behaviour for a
line-based video chip, **unconfirmed; R1 stays open until frame-by-frame
PCB footage of a mid-frame text-layer write**. The `LATCH` parameter keeps
the alternative (a snapshot at the start of line 14) built and verified.

### 5.2 Method

M0 only logged register writes per frame, so the oracle gained a VISLOG
mode (`sim/mame/t16_oracle.lua`, `mame/vislog_runs.py`): every capture was
rerun with the same frames, inputs and DIP fields, logging every tile RAM,
palette, scroll and flip write made during lines 16-239 of a dumped frame,
with the word's value before the write. Every rerun's per-frame trace
(`frames.csv`: scroll, flip, IRQ counts, sprite-buffer changes on all
12,000 frames) is byte-identical to the M0 run, so the logs belong to the
dumped frames. 672,491 writes were logged.

For each frame with such writes (`sim/m1/midscan.py`): the dump is the state
after the scan; undoing the frame's writes newest-first gives the state at
the start of the scan (INIT). The RTL is run from INIT with each write
applied through the CPU port when its beam position comes round (MAME line
unchanged, hpos scaled 256 to 384), and compared with MAME's snapshot.

### 5.3 Results

| Run | Frames | With visible writes | Value-changing | LIVE exact | LIVE explained | LATCH differs from MAME |
|---|---|---|---|---|---|---|
| fs_attract | 2,025 | 1,060 | 1,046 | 1,031 | 29 | 31 |
| fs_play | 1,326 | 1,029 | 440 | 1,015 | 14 | 191 |
| riot_attract | 2,025 | 77 | 59 | 61 | 16 | 23 |
| riot_play | 1,001 | 7 | 5 | 7 | 0 | 1 |
| ginkun_attract | 2,025 | 1,318 | 112 | 1,255 | 63 | 89 |
| fs_flip | 300 | 142 | 139 | 140 | 2 | 5 |
| riot_flip | 300 | 16 | 11 | 13 | 3 | 8 |
| ginkun_flip | 300 | 154 | 14 | 152 | 2 | 7 |
| clone_fstarfrcj | 300 | 169 | 161 | 160 | 9 | 9 |
| clone_fstarfrcja | 300 | 169 | 161 | 160 | 9 | 9 |
| clone_fstarfrcw | 300 | 166 | 157 | 158 | 8 | 8 |
| clone_riotw | 300 | 9 | 7 | 5 | 4 | 4 |
| **Total** | **10,502** | **4,316** | **2,312** | **4,157** | **159** | **385** |

"Explained" means: LIVE differs from MAME only on lines up to the last
value-changing write's line + 1, and equals INIT on every line above the
first one; the image switches from the old state to MAME's between the two
writes. The largest gap between a differing line and the last write is 1
line, which is the renderer fetching line L during line L-1. Per-frame
details: `build/m1/midscan_<run>.csv`. Text RAM is among the writes in 148
of the 159 frames (Final Star Force's text layer, as M0 predicted); the
others are tile RAM or palette changes on scene changes (the largest is
Riot frame 97, early in boot, 56,832 pixels).

Most frames with value-changing writes still match MAME (2,153 of 2,312):
the written cells are off screen, or below the beam when written, so the
line renderer reads the new value anyway.

### 5.4 Which side is believed accurate

MAME draws each frame once at vblank start, so a write during the scan
shows on all 224 lines; that is an artefact of rendering once per frame,
not a statement about the PCB. A line-based video chip reading RAM as it
draws shows the old contents above the write, which is what the core does.
The core is believed accurate for these 159 frames; MAME is believed wrong
for the lines above each write. Unconfirmed until R1's footage.

LATCH (snapshot at line 14) shows INIT on every line of every one of the
4,316 frames (checked) and differs from MAME on 385 of them, more than LIVE,
because it drops every visible-scan write. Neither reproduces MAME on these
frames; only rendering one frame behind the CPU would, at the cost of a
frame of extra display lag on every frame, which no evidence supports.

## 6. Line budget and capacity

The worst game line takes 1,988 of 6,144 clocks (clone_fstarfrcw), against
the pessimistic ROM port. `make m1-capacity` (`build/m1/capacity.txt`)
puts N sprites across one line:

| Sprite width | Most on one line without overrun | Cells |
|---|---|---|
| 8 | 256 (the whole list) | 256 |
| 16 | 256 (the whole list) | 512 |
| 32 | 166 | 664 |
| 64 | 83 | 664 |

The games' worst line in M0 is 24 sprites / 146 cells: a 4.5x margin. MAME
has no per-line limit; the PCB's is unknown (R10). An overrunning pass
delays the next line's pass (counted, never seen in game frames).

## 7. Mixer

`tecmo_mix.cpp:70-323` with tecmo16's configuration, branch for branch
(the RTL comments cite each). Coverage (`sim/m1/mix_coverage.py`):

- Synthetic scenes hit all 31 branches, including the four where MAME
  writes `machine().rand()` (mix:120, 137, 214, 261); RTL = model on all.
- The games hit 20 branches in 10,502 frames (`build/m1/mix_coverage_games.txt`).
  Never hit: the four `rand()` branches and every blended branch for
  sprites above fg or above everything (only "above bg" sprites blend in
  these games). MAME's guessed branch (mix:157-162, blended sprite above bg
  over a blended fg pixel, "WRONG??") is hit by 240,646 pixels, so that
  guess shapes real frames; it stays MAME's until PCB evidence (R6).
- `rand()` branches: the core takes the branch below each one (drops the
  blend), deterministic and the same as jtgaiden; none occurs in any
  capture, so no frame depends on the choice (R6).

Bug found by the synthetic scenes (no game frame reached it): a transparent
tile pixel kept its colour bits in the line buffer, but MAME's layer
bitmaps hold 0 there, and mix:157-162 reads the bg value even when the bg
pixel is transparent. Transparent tile pixels are now stored as 0.

## 8. MAME divergences, classified

| Divergence | Frames affected | Cause | Believed accurate |
|---|---|---|---|
| Visible-scan writes shown from the write line down instead of on the whole frame | 159 of 10,502 captured (section 5) | MAME renders once per frame; the core renders per line | Core (unconfirmed, R1) |
| Raster 264 lines / 59.19 Hz vs MAME's 256 / 59.17 Hz | none in M1 (no pixel depends on it); IRQ5 hold length in M2 | MAME's TODO guess adopted for the board (t16:20) | Unknown (R3, R9) |
| Sprites per line: core 664 cells, MAME unlimited | none (games use at most 146) | line pass budget | Unknown (R10) |
| `rand()` mixer branches: core deterministic, MAME random | none in captures | MAME placeholder | Unknown (R6) |
| Sprite list copy: engine vs instantaneous | none: copy-before-write makes it exact (section 4) | | MAME behaviour reproduced |

## 9. Not done in M1

- No synthesis: Yosys is not installed and Quartus runs on the compile PC
  in M4. On-chip RAM estimate (PLAN 4.4): about 45 M10K for the video in
  the LIVE build, about 86 with LATCH.
- The CPU side (address decode, byte lanes on the 68000 bus, IRQ5 from
  `o_vbl`) is M2; the RAM ports and register selects are ready for it.

## 10. Tooling notes

- `sim/mame/run_mame.sh` takes `RT_TAG` so parallel runs of one set use
  separate MAME runtime dirs (M0 shared one per set).
- The harness writes RAM through the CPU ports with the pixel enable
  stopped (one clock per word); mid-scan writes pause the raster for one
  clock each, which changes no pixel.
- `+dbg=1` on the harness writes each output pixel's four line-buffer
  values (`o_dbg_lay`) next to the image, for layer-by-layer comparison
  with `t16_render.layers()`.
