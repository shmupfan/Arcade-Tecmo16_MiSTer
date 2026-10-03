# jt6295 (OKI M6295)

Upstream: jotego/jt6295 (Jose Tejada, GPL-3.0, LICENSE), via the Hyper Duel
and Dooyong cores (lineage below). This directory is IDENTICAL in the
1945k III core (1945kiii-mister) and the Tecmo 16 core (tecmo16-mister) as of
2026-10-03: one consolidated patch set, three functional patches, all in
`hdl/jt6295_serial.v` (md5 of the patched file:
92d8f1eb470c314f90ae2d13864754ff). Keep the two copies identical; any
future change goes into both and is re-verified in both.

| Patch | Change | Found in | Evidence |
|---|---|---|---|
| 1 | phrase end includes the stop byte's second nibble | 1945k III M2 | below; MAME plays 2 x (stop - start + 1) samples |
| 2 | a start to a channel that is still playing is ignored | 1945k III M3 | below; MAME okim6295.cpp L281-284 |
| 3 | busy flags follow the committed channel state (updated at cen4) | Tecmo 16 M3 | below; Ginkun fade-outs |

The three do not overlap: patch 1 changes `over`, patch 2 the reload terms
(`start_ok` replaces `up_start` in `update`, `stop_in`, `cnt_in`, `att_in`,
`busy_in`), patch 3 the clock enable of the `busy` output register.
Patch 2 reads `busy_out`, the committed state in the CSR shift register,
which is the same state patch 3 makes the status register report, so a
stop committed at cen4 both shows idle and allows the next start.

## Patch 3 (Tecmo 16 M3, 2026-10-03): busy follows the committed state

The per-channel `busy` flags are updated on `cen4`, together with the
channel state in the CSR shift register, instead of on every clock of the
channel's slot. Upstream (jotego/jt6295 master, identical to the unpatched
copy) lets a pending stop show as idle for the rest of the slot (up to
33 us) before it is committed; a start command's first byte clears the
pending stop in `jt6295_ctrl.v`, so a start written in that window cancels
the stop: the old phrase plays on at its old attenuation and the new start
is ignored as busy. Ganbare Ginkun fades sounds by stop, poll status until
idle, restart at the next attenuation; with upstream jt6295 every step of
the fade was lost (the M6295 part of the mix up to 4.2 dB above MAME in 2 s
segments). After the patch the M6295 output matches MAME's level in those
segments to 0.03 dB (tecmo16-mister docs/m3_findings.md section 4).

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
restarts its phrase from the beginning. Patched: `start_ok = up_start &
~busy_out` replaces `up_start` in the reload terms, so a start to a playing
channel is ignored; the request is still acknowledged so jt6295_ctrl clears
it. A stop on the same cycle still wins.

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

The Dooyong and Hyper Duel cores are being given the same consolidated
patch set (2026-10-03, Lee's approval) by separate work in those repos.

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
