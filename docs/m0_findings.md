# M0 findings: ROM validation and MAME oracle

Date: 2026-10-02. MAME 0.288 (local oracle) against the driver vendored from
master c4fc5eb (`reference/mame/PROVENANCE.md`: 0.288 and master differ only
in constructor signatures). Reproduce everything with `cd sim && make m0`
(about 20 minutes on the Mac, 3.3 GB of gitignored output in `sim/mame/out`).

## 1. Gate verdict: PASS

| Check | Result |
|---|---|
| ROMs (`make roms-check`) | 7/7 sets complete: 9 files each, CRC32, SHA1 and size match the table generated from `tecmo16.cpp`; `mame -verifyroms` OK for all 7 |
| Regions (`make mame-regions`) | 7/7 sets, 6 regions each, byte-identical to MAME's own region dumps |
| Renderer (`make oracle-verify`) | **10,502 / 10,502 frames pixel-exact** on both checks (MAME snapshot, and screen:pixels() one notifier later where the palette did not change) |
| Mixer `machine().rand()` branches | hit by 0 pixels in all 10,502 frames |

Frames per capture (all pixel-exact):

| Run | Set | Content | Frames |
|---|---|---|---|
| fs_attract | fstarfrc | attract, every 8th frame to 12,000 + dense 4,600-5,199 | 2,025 |
| fs_play | fstarfrc | coin, start, stage 1 with boss, game over, continue, high score table, second credit (every 4th frame 700-6,000) | 1,326 |
| riot_attract | riot | attract, every 8th frame + dense 2,000-2,599 | 2,025 |
| riot_play | riot | coin, start, play (every 4th frame 700-4,700) | 1,001 |
| ginkun_attract | ginkun | attract, every 8th frame + dense 3,000-3,599 | 2,025 |
| fs_flip, riot_flip, ginkun_flip | parents | flip-screen DIP on, every 20th frame to 6,000 | 300 each |
| clone_fstarfrcj, clone_fstarfrcja, clone_fstarfrcw, clone_riotw | clones | every 30th frame to 9,000 | 300 each |

Attract loops: Final Star Force about 2,000 frames per pass (title, a
different stage demo each pass, the US "Recycle it" and "Winners don't use
drugs" screens); Riot about 5,200 (intro, title, city demo, history book).
12,000 frames cover several passes of each.

## 2. Model choices the oracle settled

- **Sprite lag is two frames.** Rendering frame N from the sprite buffer as
  it stood at notifier N-1 matches every frame. Using the buffer at
  notifier N fails on 55 (fstarfrc), 59 (riot) and 34 (ginkun) of 120
  survey frames; using live sprite RAM fails on 54, 62 and 43. So the check
  discriminates and the spec 8 model is right for MAME.
- **Text layer y offset.** Final Star Force never writes 0x160006 (text
  scroll y) in any capture, so its text layer stays at video_start's -16
  for the whole game; Riot and Ginkun write it every frame.
- **Flip screen** is driven by the game from the DIP (Final Star Force
  writes 0x150000 twice at boot; Ginkun every frame); the renderer's flip
  path (tilemap mirror and sprite remap) is exact on 900 flipped frames.
- **Blending** is used by Riot only: 92 of 2,025 attract frames and 72 of
  1,001 gameplay frames have blended sprite pixels, 40 and 33 blended fg
  pixels. Final Star Force shows blended fg pixels in 1 attract frame;
  Ginkun none. All blend branches hit are deterministic in MAME.

## 3. Interrupts and register timing

- IRQ5 count per frame (writes to 0x150031, the first instruction of the
  handler): Final Star Force 1 (6,616 frames), 4 (3,437), 3 (919), 2 (905),
  0 (116), 5 (1) in 12,000 attract frames. It never writes 0x150021, so it
  re-enters the handler while vblank holds the line (spec 4). Riot takes 1
  per frame in 99% of frames and writes 0x150021 1 to 17 times per frame.
  Ginkun writes 0x150031 and 0x150021 once per frame.
- Scroll registers are written almost only in vblank: Final Star Force
  lines 243/247/249-252 and line 0; Riot 241-250; Ginkun 240-241. Writes in
  the visible area (lines 16-239): 53 in 12,000 Final Star Force frames
  (12 change text x), 38 in Riot (6 change fg x, 6 bg x, 2 fg y), 0 in
  Ginkun.
- Unmapped video registers (R9). At boot every game writes once to
  0x160002, 0x160004, 0x160008, 0x16000a, 0x16000e, 0x160010, 0x160014,
  0x160016, 0x16001a and 0x16001c, which MAME ignores. Final Star Force's
  values: 0x1bc, 0x340, 0x000, 0x0df, 0x3c6, 0xff38, 0x010, 0x0ef, 0x3c6,
  0x135. 0x010 and 0x0ef are the first and last visible lines (16 and 239)
  and 0x0df is 223, so these look like raster or window settings and may
  answer R3. Riot rewrites 0x160008/0x16000a/0x160014/0x160016 92 times in
  12,000 frames with values such as 0xf0, 0xee, 0x11, 0x0f.
- 0x160000 is read 46 times in 12,000 Final Star Force frames, never by
  Riot or Ginkun.
- Riot writes its extra RAM at 0x124000 about 25 times per frame.

## 4. Sprite load

| Run | Max enabled sprites in a frame | Max sprites on one visible line | Max 8-px sprite columns on one line |
|---|---|---|---|
| fs_attract | 71 | 24 | 134 |
| clone_fstarfrcw | 79 | 24 | 146 |
| fs_play | 39 | 18 | 96 |
| riot_attract | 205 | 24 | 76 |
| riot_flip | 205 | 128 (all 8x8) | 128 |
| ginkun_attract | 63 | 24 | 64 |

All sizes from 8x8 to 64x64 occur; Final Star Force uses 64x64 and 32x64
most, Riot mostly 16x16.

## 5. RAM written during the visible scan (input to M1)

MAME renders each frame once at vblank start, so any value a game changes
during the visible scan shows on the whole frame in MAME. HEAVY_LOG runs
over 501 frames of each game's busiest window (`tools/midframe_writes.py`)
count frames whose visible lines (16-239) contain value-changing writes:

| RAM | fstarfrc 4,650-5,150 | riot 2,050-2,550 | ginkun 3,050-3,550 |
|---|---|---|---|
| text RAM | 362 frames (lines 16-63) | 3 | 12 |
| bg codes / colours | 7 / 7 | 3 / 1 | 3 / 0 |
| fg codes / colours | 0 / 0 | 1 / 1 | 4 / 3 |
| palette | 2 | 0 | 0 |
| sprite RAM | 361 | 0 | 92 |

Sprite RAM writes do not matter (the vblank copy isolates them). The tile
RAM and palette writes do: a line renderer reading live RAM would show the
old value on lines drawn before the write and differ from MAME, most often
in Final Star Force's text layer at the top of the screen. PLAN 4.1 keeps a
copy latched at vblank start for parity; R1 asks what the PCB does.

## 6. Reuse check

jotego's jtgaiden (jtcores `cores/gaiden/hdl`, GPL-3.0-or-later, last
change 881576a, 2026-08-25) implements the same Tecmo sprite chip family and
mixer: `jtgaiden_obj.v` (with a `frmbuf_en` frame-buffer option),
`jtgaiden_objscan.v`, `jtgaiden_colmix.v`, `jtgaiden_priority.v` and
`jtgaiden_blender.v`. The blender is a per-channel saturating 4-bit add,
which equals MAME's 8-bit `sum_colors` after `(c << 4) | c` expansion.
Licence is compatible; it depends on jtframe, so M1 decides port versus
reference.

## 7. Open questions for M1

1. Latching structure for tile RAM, palette and scroll (PLAN 4.1): a
   vblank copy (MAME parity) is the default.
2. Raster: MAME's 59.17 Hz / 256 lines or the 6 MHz / 384 x 264 guess
   (59.19 Hz). The boot-time register values (section 3) may decide it.
3. jtgaiden sprite engine and mixer: port or write new from the spec.
4. The four `rand()` mixer branches never occur in captures; the RTL needs
   a deterministic choice for them (logged, not MAME-comparable).

## 8. Tooling notes

- `sim/mame/t16_oracle.lua` reads tile RAM, palette, sprite buffer (item
  `:spriteram 0/m_buffered`), scroll (`0/m_scroll_x` etc.) and flip
  (`0/m_flip_screen_x`, stored as 0 or 255) directly; no write tracking is
  needed for state.
- `sim/oracle/compare_frames.py --sprites prev|buf|live` reruns the lag
  check.
- zsh does not split `$var` into words: shell loops over "set start end"
  triples must index explicitly.
