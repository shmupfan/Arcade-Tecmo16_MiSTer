# Tecmo 16 (Final Star Force, Riot, Ganbare Ginkun) system specification

Source of every fact: the MAME sources vendored in `reference/mame/`
(provenance in `reference/mame/PROVENANCE.md`). Citations are
`file:line`; `t16` = `tecmo16.cpp`, `spr` = `tecmo_spr.cpp`, `mix` =
`tecmo_mix.cpp`, `mixh` = `tecmo_mix.h`. Where MAME says it is guessing, the
text says so. Statements marked **(oracle)** were measured in the M0 oracle
runs (`docs/m0_findings.md`), not read from the driver.

## 1. Games and sets

| Set | Parent | Machine config | Inputs | Rotation | Title | Line |
|---|---|---|---|---|---|---|
| fstarfrc | - | base | fstarfrc | ROT90 | Final Star Force (US) | t16:1006 |
| fstarfrcj | fstarfrc | base | fstarfrc | ROT90 | Final Star Force (Japan, set 1) | t16:1007 |
| fstarfrcja | fstarfrc | base | fstarfrc | ROT90 | Final Star Force (Japan, set 2) | t16:1008 |
| fstarfrcw | fstarfrc | base | fstarfrc | ROT90 | Final Star Force (World?) | t16:1009 |
| riot | - | riot | riot | ROT0 | Riot (NMK) | t16:1011 |
| riotw | riot | riot | riot | ROT0 | Riot (Woong Bi) | t16:1012 |
| ginkun | - | ginkun | ginkun | ROT0 | Ganbare Ginkun | t16:1014 |

The driver notes the games are ROM swaps on the same board: Riot ROMs run
on a Final Star Force PCB (t16:31-32). One core covers all three.

## 2. Hardware (t16:661-713, PCB notes t16:857-911)

| Part | Clock | Source |
|---|---|---|
| MC68000 main CPU | 24 MHz / 2 = 12 MHz | t16:663, 667, 894 |
| Z80 sound CPU | 24 MHz / 6 = 4 MHz | t16:670, 895 |
| YM2151 | 24 MHz / 6 = 4 MHz, stereo 0.60 per side | t16:705-708, 896 |
| OKI M6295 | 8 MHz / 8 = 1 MHz, pin 7 high (rate 1 MHz / 132) | t16:664, 710-712, 897 |
| Tecmo customs | TECMO-5 (MCU?, 6 MHz), -06 (YM6048), -07 (YM6621), -8, -9 (MN53030), -10, -11, -12 | t16:902-910 |

MAME's quantum is 600 Hz (t16:673). The TECMO-5 "MCU?" is not emulated or
dumped; the games run without it in MAME.

## 3. Main CPU memory map

Common to all sets (t16:368-391):

| Address | Access | Function | Line |
|---|---|---|---|
| 0x000000-0x07ffff | R | program ROM (512 KB) | t16:370 |
| 0x100000-0x103fff | RW | main RAM 16 KB | t16:371 |
| 0x130000-0x130fff | RW | sprite RAM 4 KB (buffered, section 7) | t16:376 |
| 0x140000-0x141fff | RW | palette RAM, 4,096 x xBGR_444 | t16:377, 688 |
| 0x150000-0x150001 | W | flip screen (bit 0) | t16:378, 276-279 |
| 0x150011 | W | sound latch (raises Z80 NMI) | t16:379, 703 |
| 0x150020-0x150021 | R | EXTRA (riot fire buttons) | t16:380, 642-645 |
| 0x150020-0x150021 | W | clears IRQ5 (section 4) | t16:380, 354-360 |
| 0x150030-0x150031 | R | DSW2 | t16:381 |
| 0x150030-0x150031 | W | no effect in MAME ("irq ack?") | t16:381, 362-366 |
| 0x150040-0x150041 | R | DSW1 | t16:382 |
| 0x150050-0x150051 | R | P1_P2 | t16:383 |
| 0x160000-0x160001 | W | text scroll x | t16:385, 297-301 |
| 0x160006-0x160007 | W | text scroll y | t16:386, 303-307 |
| 0x16000c-0x16000d | W | fg scroll x | t16:387 |
| 0x160012-0x160013 | W | fg scroll y | t16:388 |
| 0x160018-0x160019 | W | bg scroll x | t16:389 |
| 0x16001e-0x16001f | W | bg scroll y | t16:390 |

0x160000 is also read "at every scene change" in MAME's comment (t16:384);
Final Star Force reads it 46 times in 12,000 frames **(oracle)**; the value
returned is open bus in MAME.

Tile RAM, Final Star Force (fstarfrc_map, t16:395-405):

| Address | Size | Function |
|---|---|---|
| 0x110000-0x110fff | 4 KB | text RAM (64 x 32 words) |
| 0x120000-0x1207ff | 2 KB | fg tile codes (32 x 32) |
| 0x120800-0x120fff | 2 KB | fg colours |
| 0x121000-0x1217ff | 2 KB | bg tile codes |
| 0x121800-0x121fff | 2 KB | bg colours |
| 0x122000-0x127fff | 24 KB | work RAM |

Tile RAM, Riot and Ginkun (ginkun_map, t16:407-417): text 0x110000-0x110fff,
fg codes 0x120000-0x120fff, fg colours 0x121000-0x121fff, bg codes
0x122000-0x122fff, bg colours 0x123000-0x123fff (64 x 32 each), extra RAM
0x124000-0x124fff ("for Riot", written about 25 times per frame by Riot
**(oracle)**). MAME notes the tilemap size "probably" comes from a
register it does not know (t16:373-374).

Sound CPU (t16:419-428): ROM 0x0000-0xefff, RAM 0xf000-0xfbff, OKI at
0xfc00, YM2151 at 0xfc04-0xfc05, latch read at 0xfc08, 0xfc0c no-op,
RAM 0xfffe-0xffff. Z80 NMI = latch pending (t16:703); Z80 INT = YM2151 IRQ
(t16:706).

## 4. Interrupts

IRQ5 follows the screen's vblank signal (t16:684): asserted at vblank start
and released at vblank end, so it is level-held for the whole vblank
(1000 us in MAME, "not accurate", t16:680). With the line held the 68000
takes IRQ5 again after each RTE. Writing 0x150021 releases it early
(t16:354-360).

- Final Star Force never writes 0x150021 and "relies on the interrupt being
  held for a while" (t16:17-19, 356-357): it takes 1 to 5 IRQ5s per frame,
  most often 1 or 4 **(oracle)**.
- Riot writes 0x150021 and "does not like multiple interrupts per frame"
  (t16:21-23, 357-358).
- Ginkun writes 0x150031 and 0x150021 once per frame (t16:351) **(oracle)**.

MAME's TODO guesses the real timing as a 6 MHz pixel clock, 384 clocks per
line and 264 lines (t16:20). MAME itself uses 59.17 Hz and a 256 x 256
bitmap (t16:679-682), so its 1000 us vblank is about 15 lines of 256.

## 5. Video timing and screen

MAME: refresh 59.17 Hz, screen 256 x 256, visible x 0-255, y 16-239
(t16:679-682); 256 x 224 visible. The oracle measures 256 x 256 total with
vblank starting at line 240 **(oracle)**. ROT90 for Final Star Force, ROT0
for the others (t16:1006-1014). Flip screen (0x150000 bit 0) flips all
tilemaps and sprites through the driver's flip_screen (t16:276-279,
337-338).

## 6. Graphics formats (t16:650-657)

| Region | Format | Tiles | Used by |
|---|---|---|---|
| fgtiles 128 KB | 8x8, 4bpp packed MSB first (32 bytes/tile) | 4,096 | text layer, colourbase 0x100, 16 colours |
| bgtiles 1 MB | 16x16 as 2x2 groups of 8x8 4bpp packed (TL, TR, BL, BR; 128 bytes/tile) | 8,192 | fg and bg layers, colourbase 0, 256 colours |
| sprites 1 MB | 8x8, 4bpp packed MSB first | 32,768 | sprites, colourbase 0, 256 colours |

Packed MSB: each byte holds two pixels, high nibble on the left. Tile codes
index modulo the number of tiles.

## 7. Layers

All three tilemaps use pen 0 as transparent (t16:199-201) and are drawn
into separate value bitmaps that the mixer combines (t16:314-328).

| Layer | Map | Tile | Code | Colour | Bitmap value | Lines |
|---|---|---|---|---|---|---|
| bg | 32x32 (fstarfrc) / 64x32 | 16x16 bgtiles | bgvram & 0x1fff | bgcram & 0x0f | colour*16 + pen | t16:163-172, 196, 220, 242 |
| fg | 32x32 (fstarfrc) / 64x32 | 16x16 bgtiles | fgvram & 0x1fff | fgcram & 0x1f | colour*16 + pen; colour bit 4 = blend flag (bit 8) | t16:149-161, 195, 219, 241 |
| text | 64x32 | 8x8 fgtiles | char & 0x0fff | char >> 12 | 0x100 + colour*16 + pen | t16:174-181, 197, 221, 243 |

Maps are row-major (TILEMAP_SCAN_ROWS). Scroll (MAME tilemap semantics,
`tilemap.cpp` effective_rowscroll/colscroll): screen coordinate i of the
256-pixel bitmap shows logical `(i - d + scroll) mod size`, or with flip
`(255 - i - d_flipped + scroll) mod size`; flipped tilemaps also mirror each
tile. Registers:

- bg/fg x and y: the written 16-bit value (t16:283-295), d = 0.
- text x: the written value (t16:297-301).
- text y: `written - 16` on every write (t16:303-307). Final Star Force
  starts at -16 before the first write (t16:203). Riot additionally has a
  y delta of -16 in both orientations (t16:248), so its text sits 32
  pixels above the register value. Ginkun has no initial offset.

Register values start at MAME's zero. Final Star Force first writes the bg
and fg scroll registers at frame 113 and the text x register at frame 112,
and **never writes text scroll y**, so its text layer stays at the -16
offset from video_start for the whole game. Riot first writes all six at
frame 184, Ginkun from frame 0-3 **(oracle)**.

## 8. Sprites (spr:41-178, t16:330-342)

256 entries of 8 words at 0x130000 (spr:72, 76). Word layout (spr:55-70):

| Word | Bits | Meaning |
|---|---|---|
| 0 | 0 | flip x |
| 0 | 1 | flip y |
| 0 | 2 | enable |
| 0 | 5 | blend |
| 0 | 7-6 | priority |
| 0 | 9-4 | carried into the colour (spr:157-158) |
| 1 | 15-0 | tile number |
| 2 | 7-4 | palette |
| 2 | 1-0 | x size: 8, 16, 32, 64 |
| 2 | 3-2 | y size (Final Star Force and Ginkun pass shift 2); Riot uses bits 1-0 for y as well (t16:337-338) |
| 3 | 8-0 | y position, wraps at 512 (>= 256 means negative) |
| 4 | 8-0 | x position, wraps at 512 for a 256-wide screen (spr:84-85, 133, 138-139) |

A sprite of w x h cells uses tile `number` with the low bits cleared per
size (spr:125-130) plus the `layout` table offset for each 8x8 cell
(spr:41-51, 167-168). Flip mirrors the cell order and each cell. Flip
screen inverts both flips and maps x to `256 - w*8 - x`, y likewise
(spr:143-155). Entries are drawn in list order (later on top), pen 0
transparent, clipped to the visible area, into a 16-bit bitmap with value
`((palette | attr & 0x3f0) * 16) + pen` (spr:158-172).

**Two-frame lag.** At each vblank start MAME draws the sprite bitmap from
the buffered sprite RAM, then copies the live RAM into the buffer
(t16:330-341, comment "2 frame sprite lags"). The frame displayed next uses
that bitmap. So frame N shows the live sprite RAM of vblank N-2. The oracle
confirms this: rendering frame N from the buffer at notifier N-1 is
pixel-exact on every frame, the buffer at N or the live RAM fail on 34 to
62 frames per survey game **(oracle)**.

## 9. Mixer (mix:70-323, t16:692-698, mixh:18-52)

Configuration (t16:693-698, argument order mixh:18-52):

| Setting | Value |
|---|---|
| sprite priority / blend / colour shifts | 10, 9, 4 |
| blend palettes bg, fg, tx, sprite | 0x700, 0x600, 0x500, 0x400 |
| regular palettes bg, fg, tx, sprite | 0x300, 0x200, 0x100, 0x000 |
| blend sources sprite, fg | 0x800, 0x900 |
| background pen, background blend pen | 0x300, 0x700 |
| sprite/tile priority reversed | yes (XOR 3) |

Per pixel the mixer takes sprite priority `p = (spr >> 10) & 3` XOR 3
(0 = behind all, 1 = above bg, 2 = above bg and fg, 3 = above all), sprite
blend `(spr >> 9) & 1`, sprite colour `(spr >> 4) & 15`, and the low 8
bits of each layer value; a layer is "on" when its pen (value & 15) is
non-zero. Opaque results take `palette[value + regular base]`. Blended
results add two palette colours per channel with saturation at 255
(mix:47-68), `sum(blend source, other blend base)`. The full branch table is
in `sim/oracle/t16_render.py:mix`, written line by line from mix:107-320.

Four branches write `machine().rand()` (mix:120, 137, 214, 261): a sprite
behind all over a blended fg pixel or with no layer behind it while
blended, and a blended sprite above a blended fg pixel. None of them
occurred in any captured frame **(oracle)**. MAME's own comments mark other
branches as guesses ("WRONG??" mix:162, "looks odd" mix:182).

## 10. Palette

4,096 entries of xBGR_444 (t16:688): red bits 0-3, green 4-7, blue 8-11,
expanded to 8 bits as `(c << 4) | c`. MAME starts from a black palette
(`palette_device::BLACK`, t16:688). Ranges by use: 0x000-0x0ff sprites,
0x100-0x1ff text, 0x200-0x2ff fg, 0x300-0x3ff bg (0x300 is also the
background pen), 0x400-0x7ff blend partners, 0x800-0x9ff blend sources.
MAME comments that Riot also writes 0x800 + 0x200 (t16:696).

### 10.1 When MAME samples state

The driver never forces a partial screen update, so MAME renders each frame
once, at vblank start, from the tile RAM, palette, scroll and flip state at
that moment. Writes the game makes during the visible scan therefore show
on the whole frame in MAME. On the real board the video chips presumably
read RAM during the scan; see research item R3.

## 11. Inputs and DIP switches

P1_P2 (t16:479-495, 550-566, 624-640): active-low joysticks and buttons,
starts in bits 6-7, coins active high in bits 14-15. Final Star Force and
Ginkun use buttons 1 and 2 in P1_P2; Riot uses buttons 2 and 3 there and
reads button 1 from EXTRA bits 1 (P1) and 5 (P2) (t16:642-645). DIP
switches per game: Final Star Force t16:432-477, Ginkun t16:501-548 (switch
numbering reversed, SW1:8 first), Riot t16:572-622 (Riot's Lives default is
0x00 = 4).

## 12. ROMs (Appendix A)

Every set has the same six regions (tools/build_regions.py checks it):
maincpu 0x80000 (two 256 KB ROMs, LOAD16_BYTE), audiocpu 0x10000, fgtiles
0x20000, bgtiles 0x100000 (two 512 KB, LOAD16_BYTE), sprites 0x100000 (two
512 KB, LOAD16_BYTE), oki 0x40000 with a 128 KB ROM in its lower half. The
table below is generated from the driver by `tools/check_roms.py --table`.

| Set | Region | File | Load | Offset | Size | CRC32 | SHA1 | Line |
|---|---|---|---|---|---|---|---|---|
| fstarfrc | maincpu | fstarf01.rom | LOAD16_BYTE | 0x000000 | 0x40000 | 94c71de6 | 7637aee89034d60ef74d0015db6fcbcc8689b88b | L735 |
| fstarfrc | maincpu | fstarf02.rom | LOAD16_BYTE | 0x000001 | 0x40000 | b1a07761 | efd580e06a134a8b6ed6e836eec3203c41ed03c5 | L736 |
| fstarfrc | audiocpu | fstarf07.rom | LOAD | 0x000000 | 0x10000 | e0ad5de1 | 677237341e837061b6cc02200c0752964caed907 | L739 |
| fstarfrc | fgtiles | fstarf03.rom | LOAD | 0x000000 | 0x20000 | 54375335 | d1af56a7c7fff877066dad3144d0b5147da28c6a | L742 |
| fstarfrc | bgtiles | fstarf05.rom | LOAD16_BYTE | 0x000000 | 0x80000 | 77a281e7 | a87a90c2c856d45785cb56185b1a7dff3404b5cb | L745 |
| fstarfrc | bgtiles | fstarf04.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 398a920d | eecc167803f48517348d68ce70f15e87eac204bb | L746 |
| fstarfrc | sprites | fstarf09.rom | LOAD16_BYTE | 0x000000 | 0x80000 | d51341d2 | e46c319158046d407d4387cb2d8f0b6cfd7be576 | L749 |
| fstarfrc | sprites | fstarf06.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 07e40e87 | 22867e52a8267ae8ae0ff0dba6bb846cb3e1b63d | L750 |
| fstarfrc | oki | fstarf08.rom | LOAD | 0x000000 | 0x20000 | f0ad5693 | a0202801bb9f9c86175ca7989fbc9efa47183188 | L753 |
| fstarfrcj | maincpu | 1.bin | LOAD16_BYTE | 0x000000 | 0x40000 | 1905d85d | 83d244f13064b826ccf86b5a8158478452efbf7f | L758 |
| fstarfrcj | maincpu | 2.bin | LOAD16_BYTE | 0x000001 | 0x40000 | de9cfc39 | bd7943f366a3161222848c5f9b687a6ba8c1d43a | L759 |
| fstarfrcj | audiocpu | fstarf07.rom | LOAD | 0x000000 | 0x10000 | e0ad5de1 | 677237341e837061b6cc02200c0752964caed907 | L762 |
| fstarfrcj | fgtiles | fstarf03.rom | LOAD | 0x000000 | 0x20000 | 54375335 | d1af56a7c7fff877066dad3144d0b5147da28c6a | L765 |
| fstarfrcj | bgtiles | fstarf05.rom | LOAD16_BYTE | 0x000000 | 0x80000 | 77a281e7 | a87a90c2c856d45785cb56185b1a7dff3404b5cb | L768 |
| fstarfrcj | bgtiles | fstarf04.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 398a920d | eecc167803f48517348d68ce70f15e87eac204bb | L769 |
| fstarfrcj | sprites | fstarf09.rom | LOAD16_BYTE | 0x000000 | 0x80000 | d51341d2 | e46c319158046d407d4387cb2d8f0b6cfd7be576 | L772 |
| fstarfrcj | sprites | fstarf06.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 07e40e87 | 22867e52a8267ae8ae0ff0dba6bb846cb3e1b63d | L773 |
| fstarfrcj | oki | fstarf08.rom | LOAD | 0x000000 | 0x20000 | f0ad5693 | a0202801bb9f9c86175ca7989fbc9efa47183188 | L776 |
| fstarfrcja | maincpu | fstarf01.ic1 | LOAD16_BYTE | 0x000000 | 0x40000 | 3b495b2c | 1ba5e1a7275b30534165ec7549b265cfcebfddfc | L781 |
| fstarfrcja | maincpu | fstarf02.ic2 | LOAD16_BYTE | 0x000001 | 0x40000 | 5dacfd3d | 01023f902ffee1eeb999df5dfb12d02c93308b45 | L782 |
| fstarfrcja | audiocpu | fstarf07.rom | LOAD | 0x000000 | 0x10000 | e0ad5de1 | 677237341e837061b6cc02200c0752964caed907 | L785 |
| fstarfrcja | fgtiles | fstarf03.rom | LOAD | 0x000000 | 0x20000 | 54375335 | d1af56a7c7fff877066dad3144d0b5147da28c6a | L788 |
| fstarfrcja | bgtiles | fstarf05.rom | LOAD16_BYTE | 0x000000 | 0x80000 | 77a281e7 | a87a90c2c856d45785cb56185b1a7dff3404b5cb | L791 |
| fstarfrcja | bgtiles | fstarf04.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 398a920d | eecc167803f48517348d68ce70f15e87eac204bb | L792 |
| fstarfrcja | sprites | fstarf09.rom | LOAD16_BYTE | 0x000000 | 0x80000 | d51341d2 | e46c319158046d407d4387cb2d8f0b6cfd7be576 | L795 |
| fstarfrcja | sprites | fstarf06.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 07e40e87 | 22867e52a8267ae8ae0ff0dba6bb846cb3e1b63d | L796 |
| fstarfrcja | oki | fstarf08.rom | LOAD | 0x000000 | 0x20000 | f0ad5693 | a0202801bb9f9c86175ca7989fbc9efa47183188 | L799 |
| fstarfrcw | maincpu | 1.bin | LOAD16_BYTE | 0x000000 | 0x40000 | 5bc0a9d2 | bd8ceded1b4bcaffbe220f33b22cdf434ef4cc6c | L804 |
| fstarfrcw | maincpu | 2.bin | LOAD16_BYTE | 0x000001 | 0x40000 | 8ec787cb | dd7976a334bdbc5a9264e866d4faf49fa72db3a3 | L805 |
| fstarfrcw | audiocpu | fstarf07.rom | LOAD | 0x000000 | 0x10000 | e0ad5de1 | 677237341e837061b6cc02200c0752964caed907 | L808 |
| fstarfrcw | fgtiles | fstarf03.rom | LOAD | 0x000000 | 0x20000 | 54375335 | d1af56a7c7fff877066dad3144d0b5147da28c6a | L811 |
| fstarfrcw | bgtiles | fstarf05.rom | LOAD16_BYTE | 0x000000 | 0x80000 | 77a281e7 | a87a90c2c856d45785cb56185b1a7dff3404b5cb | L814 |
| fstarfrcw | bgtiles | fstarf04.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 398a920d | eecc167803f48517348d68ce70f15e87eac204bb | L815 |
| fstarfrcw | sprites | fstarf09.rom | LOAD16_BYTE | 0x000000 | 0x80000 | d51341d2 | e46c319158046d407d4387cb2d8f0b6cfd7be576 | L818 |
| fstarfrcw | sprites | fstarf06.rom | LOAD16_BYTE | 0x000001 | 0x80000 | 07e40e87 | 22867e52a8267ae8ae0ff0dba6bb846cb3e1b63d | L819 |
| fstarfrcw | oki | fstarf08.rom | LOAD | 0x000000 | 0x20000 | f0ad5693 | a0202801bb9f9c86175ca7989fbc9efa47183188 | L822 |
| ginkun | maincpu | ginkun01.i01 | LOAD16_BYTE | 0x000000 | 0x40000 | 98946fd5 | e0b496d1fa5201d94a2a22243fe4b37d9ff7bc90 | L827 |
| ginkun | maincpu | ginkun02.i02 | LOAD16_BYTE | 0x000001 | 0x40000 | e98757f6 | 2310b5f00b9522d5a983c8686f7d5bcf2d885964 | L828 |
| ginkun | audiocpu | ginkun07.i17 | LOAD | 0x000000 | 0x10000 | 8836b1aa | 22bd5258e5971aa69eaa516d7358d87fbb65bee4 | L831 |
| ginkun | fgtiles | ginkun03.i03 | LOAD | 0x000000 | 0x20000 | 4456e0df | 1509474cfbb208502262b7039e28d37be1131a46 | L834 |
| ginkun | bgtiles | ginkun05.i09 | LOAD16_BYTE | 0x000000 | 0x80000 | 1263bd42 | bff93633d42bae5b8273465e16bdb4db81bbd6e0 | L837 |
| ginkun | bgtiles | ginkun04.i05 | LOAD16_BYTE | 0x000001 | 0x80000 | 9e4cf611 | 57242f0aac49e0569a57372e59ccc643924e9b44 | L838 |
| ginkun | sprites | ginkun09.i22 | LOAD16_BYTE | 0x000000 | 0x80000 | 233384b9 | 031735b0fb2c89b0af26ba76061776767647c59c | L841 |
| ginkun | sprites | ginkun06.i16 | LOAD16_BYTE | 0x000001 | 0x80000 | f8589184 | b933265960742cb3505eb73631ec419b7e1d1d63 | L842 |
| ginkun | oki | ginkun08.i18 | LOAD | 0x000000 | 0x20000 | 8b7583c7 | be7ce721504afb45e16eda146f12031d818fc94c | L845 |
| riot | maincpu | 1.ic1 | LOAD16_BYTE | 0x000000 | 0x40000 | 9ef4232e | b9dd3e0dc5785311ff2433b5eb94e327b51ef144 | L957 |
| riot | maincpu | 2.ic2 | LOAD16_BYTE | 0x000001 | 0x40000 | f2c6fbbf | 114cc9ede8b6b4e94dad59f82f0232e9b7fa5025 | L958 |
| riot | audiocpu | 7.ic17 | LOAD | 0x000000 | 0x10000 | 0a95b8f3 | cc6bdeeeb184eb4f3867eb9c961b0b82743fac9f | L961 |
| riot | fgtiles | 3.ic3 | LOAD | 0x000000 | 0x20000 | f60f5c96 | 56ea21f22d3cf47071bfb3555b331a676463b63e | L964 |
| riot | bgtiles | 5.ic9 | LOAD16_BYTE | 0x000000 | 0x80000 | 056fce78 | 25234fa0282fdbefefb06e6aa5a467f9d08ed534 | L967 |
| riot | bgtiles | 4.ic5 | LOAD16_BYTE | 0x000001 | 0x80000 | 0894e7b4 | 37a04476770942f292d836997c649a343f71e317 | L968 |
| riot | sprites | 9.ic22 | LOAD16_BYTE | 0x000000 | 0x80000 | 0ead54f3 | 4848eb158d9e2279332225e0b25f1c96a8a5a0c4 | L971 |
| riot | sprites | 6.ic16 | LOAD16_BYTE | 0x000001 | 0x80000 | 96ef61da | c306e4d1eee19af0229a47c2f115f98c74f33d33 | L972 |
| riot | oki | 8.ic18 | LOAD | 0x000000 | 0x20000 | 4b70e266 | 4ed23de9223cc7359fbaff9dd500ef6daee00fb0 | L975 |
| riotw | maincpu | riotw1.ic1 | LOAD16_BYTE | 0x000000 | 0x40000 | c1849b44 | a47fa87b0c73e766e3aee935fdb58341ae8856cb | L980 |
| riotw | maincpu | riotw2.ic2 | LOAD16_BYTE | 0x000001 | 0x40000 | d6dc0c09 | 1ccce338ee7ed0b909323a1649ffdffc6784f980 | L981 |
| riotw | audiocpu | 7.ic17 | LOAD | 0x000000 | 0x10000 | 0a95b8f3 | cc6bdeeeb184eb4f3867eb9c961b0b82743fac9f | L984 |
| riotw | fgtiles | 3.ic3 | LOAD | 0x000000 | 0x20000 | f60f5c96 | 56ea21f22d3cf47071bfb3555b331a676463b63e | L987 |
| riotw | bgtiles | 5.ic9 | LOAD16_BYTE | 0x000000 | 0x80000 | 056fce78 | 25234fa0282fdbefefb06e6aa5a467f9d08ed534 | L990 |
| riotw | bgtiles | 4.ic5 | LOAD16_BYTE | 0x000001 | 0x80000 | 0894e7b4 | 37a04476770942f292d836997c649a343f71e317 | L991 |
| riotw | sprites | 9.ic22 | LOAD16_BYTE | 0x000000 | 0x80000 | 0ead54f3 | 4848eb158d9e2279332225e0b25f1c96a8a5a0c4 | L994 |
| riotw | sprites | 6.ic16 | LOAD16_BYTE | 0x000001 | 0x80000 | 96ef61da | c306e4d1eee19af0229a47c2f115f98c74f33d33 | L995 |
| riotw | oki | 8.ic18 | LOAD | 0x000000 | 0x20000 | 4b70e266 | 4ed23de9223cc7359fbaff9dd500ef6daee00fb0 | L998 |

## 13. MAME uncertainties

| Item | Line |
|---|---|
| Video timing, vblank and IRQ length unmeasured; guess 6 MHz, 384 x 264 | t16:17-20, 680 |
| Riot fails with multiple IRQs per frame; meaning of 0x150021 / 0x150031 guessed | t16:21-23, 348-366 |
| Possible priority problems in Riot level 2 | t16:24-25 |
| Layer offsets unchecked | t16:26 |
| Tilemap size per game probably set by a register | t16:373-374 |
| Riot palette use at 0x800 + 0x200 | t16:696 |
| Mixer branches that write random colours, and guessed blend branches | mix:120-162, 182, 214, 261 |
| Two-frame sprite lag modelled by a vblank copy | t16:335-340 |
| fg colour bit 4 "controls blending" (category assignment commented out) | t16:154-155 |
