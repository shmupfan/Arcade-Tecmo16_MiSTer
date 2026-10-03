# jt6295 (OKI M6295)

Upstream: jotego/jt6295 (Jose Tejada, GPL-3.0, LICENSE), via the Hyper Duel
and Dooyong cores (lineage below). The patched files (`hdl/jt6295.v`,
`hdl/jt6295_ctrl.v`, `hdl/jt6295_serial.v`) are IDENTICAL in four cores as
of 2026-10-03: 1945k III (1945kiii-mister), Tecmo 16 (tecmo16-mister),
Dooyong (dooyong-mister) and Hyper Duel (hyperduel-mister). md5:

| File | md5 |
|---|---|
| hdl/jt6295.v | 5ac531e429298723ae48a064551b9685 |
| hdl/jt6295_ctrl.v | 3c275bd9d77dc5dbc89eea5d4a277aa5 |
| hdl/jt6295_serial.v | 5523e7c4708b29324ed409d16cad92a2 |

Keep the copies identical; any future change goes into all four and is
re-verified in each.

| Patch | Change | Found in | Evidence |
|---|---|---|---|
| 1 | phrase end includes the stop byte's second nibble | 1945k III M2 | below; MAME plays 2 x (stop - start + 1) samples |
| 2 | a start to a channel that is still playing is ignored | 1945k III M3 | below; MAME okim6295.cpp L281-284 |
| 3 | BUSY timed as the MSM6295 datasheet; start acceptance as MAME's "playing" flag; a start never cancels a stop; the decoder resets on every start | Tecmo 16 M3, Dooyong (R17), 2026-10-03 | below; MSM6295 datasheet p. 73; MAME okim6295.cpp |

Patch 3 replaces an earlier patch 3 (busy flags updated only at `cen4`,
shipped in 1945k III 4c790cc and Tecmo 16 da9fc02), which was found
wanting in the Dooyong core (dooyong-mister m3_findings 6.3), and a
MAME-timed version tried the same day. The datasheet (below) decided the
status timing.

## Patch 3 (2026-10-03, R17): BUSY as the datasheet, starts and stops as MAME

Evidence rule (Lee): the datasheet outranks MAME; where the datasheet is
silent, MAME is followed.

The datasheet: OKI MSM6295, later edition (OKI data book p. 59-74;
`mister-arcade-survey/datasheets/msm6295/MSM6295_datasheet4u.pdf`, md5
d8945dff2da97fb1ff0f1fa091e289f1), section 5 "Start and Stop of 1
Channel", p. 73, read independently by two people (the datasheet research
and this patch):
- "When stop is entered, voice playback stops all the next sample and BUSY
  becomes "L"." The timing diagram draws "Busy(internally)" falling at the
  first sample boundary after the stop WR.
- "When start is entered again, voice is output after 48 x n clock from
  the second byte write. BUSY becomes "H" after 15 x n clock internally."
  ("1 sample rate : 33 x n clock number SS = H : n = 4 / SS = L : n = 5".)
- "When a single channel (either of channels 1-4) starts again after it
  has stopped, the first write for start must be input with a delay of
  more than one sample rate from the stop write". A restart sooner than
  that is not described.
- p. 72: "Busy output during synthesized playback" on I0-I3 when RD is
  low; the status read is that BUSY.

MAME 0.288 (okim6295.cpp) clears a voice's `m_playing` flag at the stop
write and sets it at the start's second byte, so a read straight after a
stop shows idle and a read straight after a start shows busy: both differ
from the datasheet. MAME is followed where the datasheet is silent: a
start to a playing channel is ignored (patch 2), and a restart within one
sample of a stop plays (Ganbare Ginkun restarts 42 us after a stop; its
sounds work on the real board).

What upstream jt6295 did: status `busy | start` (a stop showed idle at
the channel's next slot, roughly the datasheet; a start showed busy as
soon as its phrase address was fetched, earlier than 15 x n); a start's
FIRST byte cleared every pending stop (Ginkun's fade steps lost, M6295 up
to 4.2 dB above MAME); a stop replaced the pending stop register; the
ADPCM decoder was reset only when a channel had been idle for a slot.

The patch (`jt6295_ctrl.v`, `jt6295_serial.v`, `jt6295.v`):
- `rdbusy`, the status read: set 15 x n master clocks after a start's
  second byte is accepted (per-channel counters; n from the SS pin),
  cleared when a stop takes effect at the channel's sample point (the
  engine commits it in the channel's slot) or when the phrase ends.
- `status`, internal, MAME's `m_playing`: set when a start is accepted,
  cleared at the stop write or at the phrase end. A start is accepted only
  if `status` is clear (patch 2), so a restart after a stop plays and a
  start to a playing channel is dropped before the engine; an ignored
  start does not disturb a start still being fetched; the phrase number
  is taken only when the start is accepted.
- A start's first byte no longer clears pending stops; a stop adds to
  them and cancels a start for its channel that has not reached the
  engine (and its BUSY delay); a start that reaches its channel wins over
  an older pending stop.
- The decoder is disabled for one sample in the slot where a start loads
  its channel (`pipe_en <= busy_out & ~start_ok`), which resets it as
  MAME's `voice.m_adpcm.reset()` on every start.
- Not modelled: the voice itself starts when the engine reaches the
  channel (about 25 us of phrase fetch plus up to one sample), not at
  48 x n clocks (single channel) or "2 samples + 15 x n" (plural); research
  item.

Unit tests (1945k III core, `sim/oki_unit`, `make`): BUSY rises 59 clocks
after the second byte (datasheet 60; one clock is the write latch) and
falls 0..93 clocks after a stop (datasheet: next sample, within 132);
Ginkun's stop + start + repeated start loads the new phrase at 8 phases.

Results against MAME (details in each core's findings):

| Game | Result | Class |
|---|---|---|
| Blue Hawk (Dooyong) | first difference frame 2,121: a status read 8 us after a stop returns 0xFB (busy), MAME 0xFA; program differs from frame 2,125 (the old R13 point) | MAME wrong per datasheet |
| Flying Tiger (Dooyong) | identical to MAME (to frame 1,200) | none |
| Sadari, Pop Bingo (Dooyong) | identical to MAME with the MAME-timed version (to frame 2,400); not re-run with the datasheet timing | not measured |
| Ganbare Ginkun (Tecmo 16) | commands identical in order and value; M6295 writes up to 280 us later (fade polls wait for the real BUSY); level -0.01 dB | MAME wrong per datasheet, timing only |
| Final Star Force play (Tecmo 16) | M6295 writes up to 99 us later; level -0.02 dB | MAME wrong per datasheet, timing only |
| 1945k III, Solite Spirits, '96 Flag Rally | output and I/O identical to the previous build (1945k III 2,001 frames, Solite 4,001, Flag Rally 2,001) | none |
| Hyper Duel, Magical Error | never read the status (MAME taps); output unchanged within 0.004 dB | none |

## Patch 1 (1945k III M2, 2026-10-02, 1945kiii-mister m2_findings 5.3): phrase end

`hdl/jt6295_serial.v`: the phrase end. Original
`assign over = rom_addr >= stop_out;` ends a voice when its byte address
reaches the stop address, after playing only the first nibble of the stop
byte: 2 * (stop - start) + 1 samples. The MSM6295 phrase table gives the
last byte of the phrase as the stop address, and MAME's okim6295 plays
2 * (stop - start + 1) samples. Patched to
`assign over = cnt >= {stop_out, 1'b1};` (end after the second nibble of the
stop byte). Measured with sim/m2/okitest (jt6295 alone, phrases 1, 5, 9,
12 and 25 of Flag Rally's bank 1): the busy bit lasted 137 one-MHz enables
(1.04 samples) less than the nominal length before the patch, 5 enables
(start latency) less after it. '96 Flag Rally polls the busy bits once a
frame and restarts its music when a channel goes idle; with the original
end its 16.8 s track ended one poll early (frame 1505 instead of MAME's
1506), and the program diverged from MAME from there.

## Patch 2 (1945k III M3, 2026-10-03, 1945kiii-mister m3_findings 3): start on a busy channel

`hdl/jt6295_serial.v`: a start command for a channel that is still playing.
The original reloads the channel (start address, stop address, attenuation)
whenever its start request comes round, busy or not, so a busy channel
restarts its phrase from the beginning. First patched in jt6295_serial
(`start_ok = up_start & ~busy_out` in the reload terms); since patch 3 the
check is made in jt6295_ctrl against MAME's `m_playing` flag, so a start to a playing channel never reaches the engine and
does not disturb a start still being fetched.

Evidence:
- MAME 0.288 okim6295.cpp L281-284: a start for a voice that is playing is
  not performed ("Requested to play sample %02x on non-stopped voice").
- jt6295's own README (lines 31-33, this copy and upstream): "The current
  JT6295 is to ignore commands to the same channel as long as the playback
  has not ended". The code did not do what the README describes; upstream
  master (jotego/jt6295, checked 2026-10-03) has the same code.
- The games: Solite Spirits and 1945k III send the same start command to a
  playing channel every frame (phrase 0x21 on channel 4, 60 times a
  second). With restarts the attack of the sample replays every frame and
  the sound is up to 15 dB louder than MAME in those stretches (Solite
  Spirits attract +7.4 dB overall, 1945k III attract +3.6 dB); with the
  patch both are within 0.04 dB of MAME and the samples match MAME's (m3).
  A game written for a chip that restarts would not re-send the command
  every frame.
- The OKI MSM6295 datasheet was not checked (jt6295's README also says the
  real chip's behaviour "has not been verified"). Research item R9 in
  docs/PLAN.md. Believed accurate: ignore, on the three points above.

The Dooyong and Hyper Duel cores carry the same files (table above).

## Lineage and other edits

Copied 2026-10-02 into the 1945k III core from the Dooyong core
(dooyong-mister/rtl/vendor/jt6295, commit
d0445799bba5e09097d14e5c65e3794cfedf2b79); the Tecmo 16 core copied it from
the Dooyong core on 2026-10-02 as well (tecmo16-mister
rtl/vendor/SOUND_PROVENANCE.md). Non-functional edits carried in both:

The Dooyong provenance note follows (it also covers jt51, which this core
does not use). Edits it lists that apply here: the ramstyle attribute in
jt6295_adpcm.v (Quartus) and the Verilator public comments in jt6295.v
(simulation only).

# jt51 and jt6295

Copied on 2026-09-28 from the Hyper Duel MiSTer core
(`hyperduel-mister/rtl/vendor/`, repository commit
e2f18f5a966213734d3f346f91e908eff52fde7d), where both are proven on
hardware. Upstream: jotego/jt51 and jotego/jt6295 (GPL-3.0, see each
LICENSE). Only `hdl/`, `LICENSE` and `README.md` were copied.

Carried-over patch (from Hyper Duel's `rtl/vendor/PATCHES.md`):
- `jt6295/hdl/jt6295_adpcm.v`: `(* ramstyle = "logic" *)` on `lut` and
  `gain_lut`, avoiding a Quartus 17.0 RAM-inference crash on these tiny
  tables. No functional change; Verilator ignores it.

Dooyong edits (simulation only, no effect on synthesis):
- `jt51/hdl/jt51_timers.v`: an `ifdef JT51_TIMER_EXACT` block (off by
  default) that counts the timers from the load write in phiM clocks, as
  MAME's ymfm does, instead of on jt51's internal sample-cycle tick. Used
  for the M3 investigation in `docs/m3_findings.md`; the core uses jt51's
  own timers.
- `jt6295/hdl/jt6295.v`: `verilator public_flat_rd` comments on the
  `busy`, `start` and `stop` wires so the harness can log channel state,
  plus `att` and `pipe_att` (Tecmo 16 M3 `+okitrace`). Simulation only.
