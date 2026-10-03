# M2 findings: full system against MAME

Date: 2026-10-03. RTL `rtl/t16_sys.sv` (68000, memory map, IRQ5, inputs,
sound latch, video) and `rtl/t16_snd.sv` (Z80 sound board), with
`rtl/t16_video.sv` from M1 in its LIVE build. Verilator 5.050 against MAME
0.288. Reproduce with `cd sim && make m2-oracle m2-stacklow m2-boot m2-promlat m2-pause
m2-hw` (the boots take hours: about 1 frame per second of simulated time per
run on the Mac).

## 1. Gate verdict: PASS

| Run (boot from power-on) | Frames | IRQ5 trace | I/O writes identical | Images: exact + mid-scan explained (unexplained) | State dumps: transient differences (persistent) |
|---|---|---|---|---|---|
| fs_attract (fstarfrc attract) | 11,993 | identical | 125,640 / 125,640 | 1,996 + 29 of 2,025 (0) | 0 of 2,025 (0) |
| fs_play (fstarfrc coin, start, play) | 6,000 | identical | 55,600 / 55,600 | 1,312 + 14 of 1,326 (0) | 0 of 1,326 (0) |
| riot_attract | 11,993 | identical | 169,888 / 169,888 | 2,009 + 16 of 2,025 (0) | 11 of 2,025 (0) |
| riot_play (Riot coin, start, play) | 4,700 | identical | 27,397 / 27,397 | 1,001 + 0 of 1,001 (0) | 2 of 1,001 (0) |
| ginkun_attract | 11,993 | identical | 108,074 / 108,074 | 1,962 + 63 of 2,025 (0) | 0 of 2,025 (0) |
| clone_fstarfrcw | 9,000 | identical | 108,269 / 108,269 | 292 + 8 of 300 (0) | 0 of 300 (0) |
| **Total** | **55,679** | **identical** | **594,868** | **8,572 + 130 of 8,702 (0)** | **13 of 8,702 (0)** |

Every row: the IRQ5 trace (per frame, the writes to 0x150030-31, which every
IRQ5 handler makes first, and to 0x150020-21, the IRQ5 clear) and the
I/O write stream (flip, sound latch, IRQ ports, every video register, in
order, value and byte lanes) are identical to MAME's for the whole run; every
captured image is either pixel-exact or explained (section 6); RAM outside
the 68000 stack and Riot's task context blocks matches at every captured
vblank or differs transiently (section 5).

Other checks:

| Check | Result |
|---|---|
| `make m2-promlat`: program ROM answering 9, 17 and 18 clocks after the request | 9 and 17: 0 late reads, I/O stream and IRQ trace byte-identical; 18: 91 late reads, the program crashes (5,952 unmapped accesses). The bus runs with no wait state for any ROM latency up to 17 clocks at 96 MHz; the M4 SDRAM controller answers in 8-9 (section 3) |
| `make m2-pause`: i_pause for 120 frames from vblank 700 | main, work and sound RAM frozen on 120 / 120 vblanks, no interrupt acknowledged during the pause, 60 IRQ5 handler entries in the 20 frames after it, the game runs on (RAM changes) |
| Soak: the fs_attract boot runs 20,001 frames (about 5.6 minutes of game time) | after the boot RAM-test frame: 0 line overruns, 0 video snapshot errors, 0 program ROM writes, 0 late program reads, 0 sound-side unmapped accesses; the only counted unmapped accesses are 78 reads of 0x160000 and the 15 boot writes of section 7 |
| Verilator build | no errors; warnings only from the vendored cores (timescale, lint classes suppressed as in the Dooyong and 1945k III cores) |

## 2. What was built

| File | Content |
|---|---|
| `rtl/t16_sys.sv` | fx68k at 12 MHz (two-phase enables, 24 MHz / 2, t16:663); exact memory map for the three machines (spec 3); IRQ5 from the vblank signal for IRQ_HOLD clocks, cleared early by a write to 0x150020-21; autovectored; byte writes carry the byte on both lanes; flip from data bit 0 on any lane; sound latch on the low byte of 0x150011; inputs P1_P2, DSW1, DSW2, EXTRA; zero-wait program ROM interface; pause |
| `rtl/t16_snd.sv` | T80 at 4 MHz, sound ROM in block RAM (downloaded), 3 KB + 2 bytes of RAM, latch with pending flag driving NMI (cleared by the Z80's read of 0xFC08), YM2151 (jt51) at 4 MHz on INT, M6295 (jt6295) at 1 MHz pin 7 high, stereo mix at MAME's routing gains (0.60 YM per side, 0.40 OKI to both; M3 calibrates) |
| `rtl/vendor/` | fx68k, T80, jt51, jt6295 copied byte for byte from the Dooyong core with their provenance files (`rtl/vendor/README.md`) |
| `sim/m2/tb_sys.cpp` | harness: SDRAM image, sound ROM download, program ROM model with latency, graphics and OKI ROM models, input events from the oracle's inputs.csv, per-frame dumps, I/O log, IRQ trace, events log (overruns, unmapped accesses) |
| `sim/m2/compare.py` | the comparison of section 1 |
| `sim/m2/pause_check.py`, `sim/m2/hw_raster.py` | pause test, raster comparison |
| `sim/mame/t16_oracle.lua` | new modes: `MAINRAM=1` (main, work and sound RAM, the 68000's SP/PC/SR at each notifier, every read of the I/O and video register ports with the value MAME returned), `STACKLOW=1` (the 68000 stack's low-water mark) |

### 2.1 Top-level ports of t16_sys (for the M4 board wrapper)

| Port | Dir | Meaning |
|---|---|---|
| `clk`, `rst_n` | in | system clock (CLK_HZ, 96 MHz), reset |
| `i_machine[1:0]` | in | 0 Final Star Force, 1 Riot, 2 Ginkun (from the MRA) |
| `i_pause` | in | stops the 68000, Z80, YM2151 and M6295 enables; video keeps scanning |
| `o_prom_req`, `o_prom_addr[18:1]`, `i_prom_data[15:0]`, `i_prom_ok` | | program ROM, 512 KB of 16-bit words (SDRAM 0x000000); data latched when ok, which must come within 17 clocks of the request (section 3) |
| `o_rom_req`, `o_rom_addr[21:0]`, `i_rom_gnt`, `i_rom_rv`, `i_rom_data[31:0]` | | graphics ROM port of t16_video (M1): byte address in the PLAN 4.3 layout, pipelined, in-order returns |
| `i_snd_dl_we`, `i_snd_dl_addr[15:0]`, `i_snd_dl_data[7:0]` | in | sound ROM download (audiocpu region, 64 KB) into block RAM |
| `o_oki_addr[17:0]`, `i_oki_data[7:0]`, `i_oki_ok` | | M6295 sample ROM (256 KB region, SDRAM 0x2b0000); data valid when ok |
| `i_p1p2`, `i_dsw1`, `i_dsw2`, `i_extra` | in | 16-bit port values as MAME reads them: P1_P2 idle 0x3FFF (coins active high in bits 14-15), DSW1/DSW2 0x00xx (the switch byte in the low half), EXTRA 0xFFFF on Riot (button 1 in bits 1 and 5, active low) and 0x0000 on the others (MAME's empty port) |
| `o_r`, `o_g`, `o_b`, `o_de`, `o_hblank`, `o_vblank`, `o_hs`, `o_vs`, `o_ce_pix` | out | video (t16_video) |
| `o_vbl`, `o_vid_busy` | out | one clock at the start of line 240; sprite copy running |
| `o_left`, `o_right` | out | signed 16-bit audio |
| `o_dbg_*`, `o_cpu_pc_dbg` | out | gate counters: line overruns and worst line, video snapshot errors, program ROM writes, unmapped accesses, late program reads, writes to the ignored video registers (R9), sound-side unmapped accesses |

Parameters: `CLK_HZ`, `PIX_NUM`/`PIX_DEN` (pixel enable fraction), `V_TOTAL`,
`IRQ_HOLD` (clocks), `LATCH` (t16_video).

## 3. Program ROM without wait states

The program ROM is in SDRAM on the board. A real 68000 reading an EPROM runs
without wait states, so the core must too: a read that waited for the SDRAM
would slow every instruction fetch. t16_sys asserts DTACK for a program read
in the same clock as any other read and keeps loading the ROM word into the
read latch until `i_prom_ok`. fx68k captures read data on every phi2 from T3
to the end of the cycle; the last capture is 20 system clocks after AS falls
at 12 MHz (2.5 CPU clocks of 8 clocks). With one clock kept spare, data that
arrives up to 17 clocks after the request is used with no wait state
(`PROM_LIMIT`); `o_dbg_prom_late` counts any read later than that.
`make m2-promlat` shows the margin is real: 17 clocks gives a byte-identical
run, 18 clocks breaks the program. The harness's default model answers in 9
clocks (the M4 SDRAM controller's worst case at 96 MHz) and puts 0xDEAD on
the bus before ok, so an early capture would show.

## 4. Clocks and the raster

All CPU and sound enables are exact fractions of the 96 MHz clock: 68000
phases every 4 clocks, Z80 and YM2151 every 24, M6295 every 96.

The gate needs MAME's frame timing, because Final Star Force's game logic
depends on how many IRQ5s it takes per frame (1 to 5, from how long the
line is held, spec 4). The `m2` build therefore runs MAME's raster: 256
lines at 59.17 Hz (t16:679-681). A pixel enable of 47336/781250 of the clock
gives 384 pixel periods per 256-pixel MAME line, so a frame is exactly
96,000,000 / 59.17 clocks on average, MAME's frame period. IRQ5 is held
96,000 clocks, MAME's 1000 us vblank (t16:680). With that, the IRQ5 trace
matches MAME frame for frame in every run.

The hardware-default build (`m2_hw`) keeps M1's raster: 6 MHz, 384 x 264
(59.19 Hz), MAME's TODO guess (t16:20). `make m2-hw` boots each parent for 3,001 frames with it and the same 1000 us
IRQ5. The games run normally: the IRQ5 entries per frame have the same
distribution as MAME's (Final Star Force 0:115, 1:1,317, 2:181, 3:289,
4:1,099 against MAME's 0:115, 1:1,318, 2:181, 3:288, 4:1,098, 5:1; Riot and
Ginkun identical), Riot and Ginkun frame 2,993 are pixel-identical to MAME's,
Final Star Force's attract demo drifts from MAME's in detail (its per-frame
trace first differs at frame 114; frame 2,993 shows the same scene with
sprites in other places), as expected when the frame and line lengths
change.

## 5. State differences, classified

At every captured vblank the harness dumps palette, text, fg/bg tile RAMs,
live sprite RAM, the sprite buffer, scroll registers, text-y flag and flip
(compared with the M0 capture), and main, work and sound RAM (compared with
the M2 MAME run). Everything outside the classes below matches.

| Class | Where | Cause | Believed accurate |
|---|---|---|---|
| Interrupted context | IRQ5 exception frame (interrupted PC, SR), saved registers of IRQ5 handler instances anywhere on the 68000 stack between its low-water mark and the initial SSP, Riot's task control blocks, the D0 value the handlers write to 0x150031/0x150021 | the interrupt lands a few CPU cycles apart from MAME's: our I/O writes land between 21 pixels (about 43 CPU cycles) earlier and 24 pixels later than MAME's, mean about +2.5 pixels (one excursion of 88 pixels, below). fx68k models the real 68000's interrupt acknowledge and autovector cycle, which is synchronised to the E clock and varies in length; MAME's 68000 times it differently (the same effect as the Dooyong core's R16). The saved values are the interrupted code's registers and PC; the code resumes and produces the same results | fx68k (cycle-exact 68000) |
| Boundary writes | a word written within a few pixels of the vblank instant (main 0x103948 at Riot frame 41, text RAM at Riot frame 121, bg RAM at Riot gameplay frame 3520) | same timing offset: the write lands on the other side of the dump instant; the next dump matches | as above |
| Sound RAM | 0xf000-0xfbff: the Z80 stack, and after a music command the sequencer (5.1) | MAME runs the sound CPU in timeslices of its 600 Hz quantum (t16:673), so at a frame notifier the Z80 can be up to 1.7 ms from the main CPU's time; the sequencer offset is in 5.1. Informational here (the sound board cannot affect the 68000: nothing reads back from it); M3 compares the sound streams | M3 |

Riot's task kernel: the IRQ5 handler (vector 0xbfc via 0x100000 to 0xc10)
writes 0x150031, and if the interrupted code was a user-mode task, saves its
registers (`movem.l d0-a5`, PC, SR) into a task control block at
A6 = 0x10000a + offset (0x117e-0x11ac) before dispatching. A MAME write tap
on the save instruction over 12,000 attract frames found three TCBs
(A6 = 0x1000fa, 0x10014a, 0x10028a). Their saved registers differ whenever
the task was preempted at a different instruction; the comparison lists them
separately (`TASK_CONTEXT` in compare.py).

Stack low-water marks (MAME, `STACKLOW=1`, lowest SP at any main RAM write
over each capture): Final Star Force 0x1037b0 (it re-enters IRQ5 while the
line is held, so handler frames nest), Riot 0x103ff0, Ginkun 0x1002b4 (its
SSP is 0x100300). At every notifier MAME's SP shows the main loop running
with an empty stack.

Transient differences outside those classes (13 dumps, all Riot, none
repeated on the next dump):

| Run, vblank | Memory | Cause |
|---|---|---|
| riot_attract 41 | main 0x103948 | boundary write (above) |
| riot_attract 121 | text RAM 0x1105d0 | written at line 239, pixel 382 in our run (just before the dump) and just after the notifier in MAME |
| riot_attract 1729, 2022-2024, 2304, 2307, 2589, 2590 | main 0x10177c | a Riot task's own stack: the return address it holds depends on where the task was preempted |
| riot_attract 7025 | fg RAM 0x120590 | written at line 239, pixel 375 in our run, after the notifier in MAME |
| riot_play 3520 | bg RAM 0x1226e0 | written at line 239, pixels 356-366 in our run, after the notifier in MAME |
| riot_play 4380 | main 0x10177c | task stack, as above |

Beam position of the I/O writes against MAME's (1 pixel = 2.06 CPU
clocks): mean +2.5 to +2.9 pixels per run, range -21 to +24 pixels, with one
excursion in clone_fstarfrcw frame 3166 where ten consecutive writes of one
IRQ5 pass land 88 pixels (about 180 CPU clocks) earlier than MAME's: an
interrupt re-entry of Final Star Force's level-held IRQ5 starting at a
different point (R11). Order and values are unaffected.

### 5.1 Sound RAM (input to M3)

The 68000's sound command stream (every write to 0x150011) matches MAME's in
order and value on every run, so whatever the sound board does is driven
identically. Its RAM tracks MAME's apart from the Z80 stack until a music
command: after Ginkun's command 0x01 at frame 785 (first difference in the
sequencer at frame 793) and from about frame 920 of Final Star Force's
gameplay, the channel blocks (stride 0x50 from 0xf291) hold counters exactly
one tick apart from MAME's (for example 21/22, 93/94, then 249/250), and stay
one tick apart. Riot's gameplay run never diverges in 4,700 frames, nor do
the attract runs of Final Star Force and Riot outside the stack. A build with
jt51's simulation-only MAME-style timer model (`JT51_TIMER_EXACT`) diverges
on the same Ginkun frame, so the YM2151 timer phase is not the cause.
Remaining candidates for M3: where the latch write falls against the sound
driver's tick (our 68000 writes land a few pixels from MAME's, R11), the
Z80's NMI entry timing, and MAME's 600 Hz scheduling quantum (t16:673).

## 6. Images

| Class | Count | Meaning |
|---|---|---|
| exact | 8,572 | pixel-identical to MAME's snapshot |
| mid-scan | 130 | our own log has visible-scan writes to tile RAM, palette, scroll or flip; explained as below |
| overrun | 0 | (Final Star Force's boot RAM-test frame is not in any capture, see below) |
| unexplained | 0 | |

Mid-scan frames are explained by the M1 criterion with our own write log:
rows above the first visible-scan write equal `t16_render.py` of the state
at the start of the scan (our previous vblank dump plus our writes before
line 16), rows below the last write + 1 equal MAME's snapshot. The core
reads live (PLAN 4.1.1, Lee 2026-10-02); R1 stays open.

Final Star Force's power-on RAM test fills sprite RAM with 0xFFFF for one
frame (MAME frame 16): 256 enabled 64 x 64 sprites, 2,048 8-pixel cells on
every line. The line pass overruns on 49 lines of that frame (worst 17,204
clocks); MAME draws every sprite (the palette is still mostly black, 169
non-black pixels). No capture holds that frame. Every Final Star Force run
logs exactly those 49 overrun lines in that frame (47 on the 264-line
raster) and none afterwards; Riot and Ginkun log none. A real board has a per-line sprite limit (R10);
what it shows on that frame is unknown.

## 7. Unmapped and ignored accesses

MAME and the core ignore the same addresses; the core counts them.

| Access | Game | Note |
|---|---|---|
| reads of 0x160000 | Final Star Force, at scene changes | returns 0, as MAME (its read log shows 0) (R7) |
| writes to 0x160002-0x16001c (ten words) | all, at boot; Riot rewrites four of them during play | R9 |
| writes to 0x160020, 0x160022, 0x16002e | all | past the end of MAME's video register map (t16:384-390); more video settings, R9/R13 |
| writes to 0x150060-0x150067 | Riot (each frame, from the table at 0x12fa), Ginkun (0x150066) | unknown I/O, R13 |
| writes to 0x150080-0x1500fe | all, at boot | unknown I/O (values 0x0f80, 0x0f00, ...), R13 |

## 8. Decisions for Lee

1. **Raster and IRQ5 length for the release build.** The gate runs MAME's
   59.17 Hz, 256-line raster with MAME's 1000 us IRQ5. The hardware-default
   build has M1's 6 MHz, 384 x 264 raster (MAME's own guess for the board)
   with the same IRQ5 length. Riot and Ginkun stay frame-exact with MAME on either raster over 3,000 frames; Final Star Force's demo drifts on the 264-line raster, because its IRQ count per frame depends on the raster. Neither is measured (R3); the
   ten boot-time video registers (R9: 0x010 and 0x0ef are lines 16 and 239)
   may define the real raster.
2. **The 68000 interrupt timing** stays fx68k's (hardware-accurate); its
   only visible effects are the classes in section 5.

## 9. Research items added

| # | Question | Evidence that would close it |
|---|---|---|
| R11 | The exact interrupt acknowledge timing on the board (fx68k's E-clock-synchronised autovector against MAME's), which sets where IRQ5 lands in the code | a logic-analyser capture of AS/IPL/VPA on a PCB, or two PCB-recorded runs of a demo that diverges with timing |
| R12 | What a read of the YM2151 at A0 = 0 (0xFC04) returns on the board; the core returns 0xFF as MAME's ymfm | YM2151 datasheet / chip test |
| R13 | Unmapped I/O at 0x150060-0x150067 and 0x150080-0x1500fe, and video registers 0x160020-0x16002e: what they drive | PCB schematic or tracing (TECMO-5, R5) |
