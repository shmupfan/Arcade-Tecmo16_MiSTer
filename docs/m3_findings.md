# M3 findings: sound against MAME

Date: 2026-10-03. RTL `rtl/t16_snd.sv` (T80 sound CPU, sound latch and NMI,
jt51 YM2151 on INT, jt6295 M6295, stereo mix) inside `rtl/t16_sys.sv`.
Verilator 5.050 against MAME 0.288. Reproduce with
`cd sim && make m3` (`m3-oracle`: MAME with the sound event log and a
48 kHz WAV; `m3-boot`: the same five runs in the core; `m3-compare`); the
core runs take about 3 hours for 3,600 frames each on the shared Mac.

## 1. Gate verdict: PASS

| Run (boot from power-on, 3,600 frames = 60.8 s) | Writes: same / boundary / reorder / differ | Sound RAM dumps: transient (persistent) | Level below 3.5 kHz (envelope correlation) |
|---|---|---|---|
| fs_attract (Final Star Force attract) | 3,310 / 267 / 24 / 0 | 4 of 90 (0) | -0.00 dB (0.998) |
| fs_play (coin, start, play; M0 inputs) | 3,351 / 243 / 7 / 0 | 7 of 146 (0) | -0.02 dB (0.999) |
| riot_attract | 3,587 / 14 / 0 / 0 | 0 of 195 (0) | +0.22 dB (0.989) |
| riot_play (coin, start, play; M0 inputs) | 3,598 / 2 / 1 / 0 | 0 of 146 (0) | +0.14 dB (0.992) |
| ginkun_attract | 3,284 / 313 / 4 / 0 | 6 of 195 (0) | -0.02 dB (0.999) |

Every event the sound board produces (68000 latch writes, Z80 writes to the
YM2151 and the M6295, IRQ and NMI entries; 586,339 core events against
MAME's log) is identical in content to MAME's on every frame of every run;
the only differences are an event a few microseconds across a vblank and,
on 36 frames, an NMI taken one instruction earlier or later (section 3).
The sound RAM never differs persistently. The level matches within 0.22 dB
in the gate band. Gate counters: 0 sound-side unmapped accesses, 0 sound
ROM writes in every run.

Columns:
- **Writes**: every 68000 latch write and every Z80 write to the YM2151 and
  the M6295, plus every Z80 IRQ and NMI entry, grouped by the frame they
  fall in and compared in order and value. *same* = identical; *boundary*
  = an event within microseconds of the vblank lands in the neighbouring
  frame (a run of frames matches as a whole); *reorder* = the same events,
  with an NMI taken one instruction earlier or later against an
  interrupt-driven YM write (section 3). No frame differs in content.
- **Sound RAM**: 0xF000-0xFBFF and 0xFFFE-0xFFFF against MAME's M2 oracle
  dumps (every fifth dump frame); the Z80 stack region above its low-water
  mark (0xFB80-0xFBFF) is interrupted context and reported separately.
  *persistent* = a byte that differs on three consecutive dumps.
- **Level**: RMS of the core's stereo mix against MAME's WAV over the run,
  below 3.5 kHz (section 5 explains the band), with the correlation of the
  20 ms envelopes.

## 2. Root cause of M2's one-tick sequencer offset: the YM2151 busy flag

M2 (m2_findings 5.1) found the sound program's channel counters one tick
apart from MAME's after a music command (Ginkun from frame 785, Final Star
Force gameplay from about frame 920). Cause, found with the new event logs:

- The sound driver writes a YM2151 register, then polls the status at 0xFC05
  until the busy bit (bit 7) clears, after every data write (285,000 data
  writes in the five runs).
- `t16_snd` strobed jt51's chip select for one 96 MHz clock. jt51 takes the
  register value on any clock, but sets its busy flag only for a write that
  coincides with its `cen_p1` enable (`jt51_mmr.v`: the busy update sits
  under `cen`), which is high on one clock in 48. So the core almost never
  reported busy: at the first music write of Ginkun (frame 75) MAME's status
  read returned 0x80 and the core's 0x00, and every busy-wait loop ran short.
- The sound program's timing against the YM timer interrupt and the NMI
  from the 68000 then drifted, and one music tick fell on the other side of
  a timer interrupt.

Fix (`t16_snd.sv`): a Z80 write is held and presented to jt51 on the next
`cen_p1` clock (at most 0.5 us later, below the chip's own internal
sampling). Busy then lasts as on the chip and in MAME's ymfm: ymfm sets it
for 32 x prescale 2 = 64 master clocks (`ymfm_opm.cpp` `write_data`), jt51
for 32 `cen_p1` periods. Measured in Ginkun's first 900 frames: busy is seen
up to 9.00 us after a data write and never from 17.25 us (MAME: 8.75 us and
17.00 us). Across the five runs the number of busy polls after each data
write equals MAME's for 272,433 of 272,440 writes (the 7 differ by one poll).

Result: the sound RAM has no persistent difference in any run (M2: lasting
from frame 793 / 920), and the write streams never differ in content.

Believed accurate: the core now. Busy for every data write is the chip's
documented behaviour and MAME's model; the one-clock strobe was a wiring
error.

**The Dooyong core has the same wiring** (`dy_snd.sv`: `.cs_n(!(wr &&
s_ym))` into jt51), so its busy flag is also almost never set. That is a
strong candidate for the unexplained part of Dooyong's R13 (sound programs
taking different decisions after 35-47 s). Not changed here; decision for
Lee (section 8).

## 3. Remaining timing difference: the YM2151 timer phase

With the busy fix the sound CPU still runs at a constant phase from MAME's:
every IRQ (YM timer) entry comes 12.5 us later than MAME's on Final Star
Force and Ginkun (median; 0.5-3.5 us on Riot). Every Z80 event inherits the
phase. Effects, all transient:

- *boundary* frames: an event within the phase of a vblank falls in the
  next frame;
- *reorder* frames: the 68000's latch write and the Z80's NMI land within
  the phase window of a YM write or IRQ entry, so MAME takes the NMI after
  that write and the core before it (or the reverse). Both continue with the
  same event sequence. Example, Final Star Force gameplay frame 1,542: latch
  0x02 at 26,060.561 ms on both; MAME's Z80 writes YM 0x0f at .5622 ms and
  takes the NMI at .5657 ms, the core's Z80 (12.5 us behind) takes the NMI at
  .5657 ms and writes YM 0x0f at .6175 ms.

Root cause: jt51 steps its timers on its internal sample cycle (64 master
clocks), so an overflow lands on that cycle; MAME's ymfm counts the exact
duration from the write. Proof: the build with jt51's simulation-only
`JT51_TIMER_EXACT` timers (MAME's model) brings the IRQ phase to +0.5 us
(median, max 3.5 us) over Final Star Force's first 1,700 gameplay frames,
with 14 boundary frames and 1 reorder (a 1.25 us race at frame 1,048), against
84 and 1 with jt51's timers over the same frames.

Believed accurate: jt51. The YM2151 clocks its timers once per sample
cycle: Nuked-OPM, built from the die, increments timer A only when its
cycle counter is 0 (`opm.c` 1363, `timer_a_inc = ... (timer_a_load &&
chip->cycles == 0)`). On a board the phase between the YM2151's internal
cycle and the CPUs is set at reset release, so this is a power-on phase, not
an error in either. The core keeps jt51's timers (research item R15).

## 4. M6295: a jt6295 stop could be cancelled (fixed)

Ganbare Ginkun fades sound effects by repeated stop, poll the status until
the channel is idle, restart the phrase one attenuation step down. In the
core the fade never happened and the M6295 part of the mix ran up to 4.2 dB
above MAME's in 2 s segments with the same waveform (correlation 0.989, RMS
ratio 1.59 at 16.9 s).

Trace (`+okitrace`): after the stop command, jt6295 showed the channel idle
(the driver's poll saw it and moved on), then the start command's first
byte cleared the pending stop, the channel's busy came back, the old phrase
played on at its old attenuation, and the new start was ignored as busy.
Cause in jt6295 (upstream master, identical to this copy):
`jt6295_serial.v` updates the reported busy flag on every clock of the
channel's slot, while the channel state in the CSR shift register is only
committed at `cen4` (up to 33 us later); `jt6295_ctrl.v` clears the pending
stop on any start command.

Patch (`rtl/vendor/jt6295/hdl/jt6295_serial.v`, documented in
`rtl/vendor/SOUND_PROVENANCE.md`): the busy flags update on `cen4`,
together with the committed state, so the status shows idle only once the
stop has taken effect. Result on Ginkun's first 1,100 frames: the M6295
level against MAME goes from +1.31 / +0.86 / +4.22 dB (12-18 s, 2 s
segments) to -0.00 / -0.03 / -0.00 dB; write streams unchanged (identical,
34 boundary frames).

Believed accurate: the patched core. The game's own logic (wait for idle,
then restart quieter) only produces its fade if a stop that reads as idle
has stopped the channel. MAME stops at once.

Remaining M6295 difference, informational: the status reads busy until the
channel's turn in jt6295's loop commits the stop (3.5 us to 134 us after
the stop command, one sample period at most; Ginkun median 68.8 us), where
MAME reads idle 3.2-3.3 us later. The driver polls until idle, so the core
makes more status reads (Ginkun: 9,393 against MAME's 945 in 3,600
frames), and the writes after a poll land later (up to 0.40 ms) in the same
order and value. On the chip the stop is
processed in the channel's turn of its time-multiplexed loop; the exact
latency is unmeasured (R14).

## 5. Level and mix

Gains are MAME's routing (tecmo16.cpp 707-712): YM2151 left and right at
0.60 to their own side, M6295 at 0.40 to both. In core units: jt51
`xleft` / `xright` (16-bit full scale) x 154/256; jt6295 output (sum of
four channels in 12-bit units, 2048 = full scale as MAME's `add_int(...,
2048)`) x 0.40 x 16 = 6.4 (`OKI_GAIN` 1638/256).

Checked:
- M6295 gain: in Ginkun windows where only the M6295 plays and the waveforms
  correlate above 0.98 with MAME's (7 windows of 0.25 s), the RMS ratio of
  MAME to the core's raw M6295 is 6.41 (6.35-6.42), against 6.4 nominal.
- YM2151 gain: jt51 and ymfm are not sample-identical, so it is fitted on
  20 ms band-limited powers in windows where the YM2151 dominates: 0.59
  (Riot, 407 windows), 0.65 (Final Star Force, 555), 0.68 (Ginkun, 153),
  against 0.60 nominal. The spread is the synthesis difference between the
  two models on each game's instruments (within -0.1 to +1.1 dB).

Band: the gate compares below 3.5 kHz, where both models are meant to
agree. Full band the core is +0.14 to +0.18 dB above MAME on the games with
M6295 sound and +2.0 to +2.1 dB on Riot (YM2151 only): jt51's output runs
at its own 55.9 kHz rate and the harness takes it at 48 kHz with no filter,
while MAME's resampler removes the content above its passband. On the
MiSTer the core's audio goes out without that filter, as the chip's DAC
output does on a board before its analogue stage. Gains unchanged; the
pre-patch +0.6 to +2.4 dB full-band excess on Final Star Force and Ginkun
was the jt6295 stop bug (section 4), not the band.

## 6. R12: YM2151 read at A0 = 0

No game reads 0xFC04 in any run (0 reads in the five MAME logs, which read
0xFC05 637,000 times). The core's 0xFF (MAME's ymfm value) is never used;
R12 stays open but cannot affect these games.

## 7. Built

| File | Content |
|---|---|
| `rtl/t16_snd.sv` | YM2151 writes held until jt51's `cen_p1` (section 2); `verilator public_flat_rd` comments for the harness |
| `rtl/vendor/jt6295/hdl/jt6295_serial.v` | busy flags at `cen4` (section 4) |
| `sim/m2/tb_sys.cpp` | `+snd` sound event log, `+wav` stereo mix at 48 kHz, `+wavsep` YM2151 and M6295 before the mix, `+ztrace` sound CPU fetches, `+okitrace` M6295 channel state |
| `sim/mame/t16_oracle.lua` | `SNDLOG=1` sound event log with MAME's emulated time (latch writes, YM/M6295 writes and reads, IRQ/NMI entries at opcode fetch), `SNDTRACE=F0:F1:file` debugger trace of the sound CPU |
| `sim/m3.mk` | `m3-oracle`, `m3-boot`, `m3-compare`, `m3` |
| `sim/m3/align_snd.py` | event-by-event alignment, first difference and largest time deltas |
| `sim/m3/frame_summary.py` | per-frame classes: same, boundary, reorder, differ |
| `sim/m3/compare_sndram.py` | sound RAM against MAME's dumps, stack separated, persistent vs transient |
| `sim/m3/compare_audio.py` | level (full band and below 3.5 kHz) and envelope correlation against MAME's WAV |
| `sim/m3/fit_gains.py` | YM2151 / M6295 gain fit on band-limited window powers |

The 68000 side is unchanged by M3: nothing on the sound board is read by
the 68000, so M2's gate results stand.

## 8. Decisions for Lee

1. **Dooyong's YM2151 busy wiring.** `dy_snd.sv` strobes jt51's chip select
   for one clock, so busy is almost never set (section 2). The same fix
   (hold the write until `cen_p1`) is likely to remove most of Dooyong's
   R13 stream divergences. Needs a Dooyong M3 rerun and a new build; not
   done here.
2. **jt6295 busy patch in the other cores.** Dooyong and Hyper Duel carry
   the unpatched jt6295 (section 4). A game that stops a channel and
   restarts it inside the same slot would lose the restart there. Worth
   checking their M6295 command streams for stop-then-start pairs.
3. **jt6295 stop byte.** The 1945k III core patched jt6295 to play the stop
   byte's last nibble (its R7). This core does not carry that patch; its
   effect here would be one sample (132 us) more per phrase.

## 9. Research items added

| # | Question | Evidence that would close it |
|---|---|---|
| R14 | How long the M6295 takes to report a channel idle after a stop command (jt6295: up to one channel slot; MAME: at once) | logic-analyser capture of the status after a stop on a real MSM6295 |
| R15 | The YM2151 timer phase against the CPUs after reset (jt51 steps timers per sample cycle, as Nuked-OPM; MAME counts from the write) | a PCB recording of a timing-sensitive sound sequence, or a capture of the YM2151 IRQ line against the sound CPU's reset |
