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
  `busy`, `start` and `stop` wires so the harness can log channel state.

## Tecmo 16 changes (M3, 2026-10-03)

Functional patch, synthesised (`jt6295/hdl/jt6295_serial.v`): the per-channel
`busy` flags are updated on `cen4`, together with the channel state in the
CSR shift register, instead of on every clock of the channel's slot.
Upstream (jotego/jt6295 master, identical to this copy before the patch)
lets a pending stop show as idle for the rest of the slot (up to 33 us)
before it is committed; a start command's first byte clears the pending stop
in `jt6295_ctrl.v`, so a start written in that window cancels the stop: the
old phrase plays on at its old attenuation and the new start is ignored as
busy. Ganbare Ginkun fades sounds by stop, poll status until idle, restart
at the next attenuation; with upstream jt6295 every step of the fade was
lost (the M6295 part of the mix up to 4.2 dB above MAME in 2 s segments,
same waveform). After the patch the M6295 output matches MAME's level in
those segments to 0.03 dB. docs/m3_findings.md section 4.

Simulation only (Verilator comments, no effect on synthesis):
- `jt6295/hdl/jt6295.v`: `verilator public_flat_rd` on `att` and
  `pipe_att` (M3 trace `+okitrace`).

2026-10-03: superseded by one consolidated jt6295 patch set shared with the
1945k III core (patches 1, 2 and 3: inclusive stop byte, start to a busy
channel ignored, and, as replaced the same day, BUSY timed as the MSM6295
datasheet with starts accepted as MAME's "playing" flag and a decoder
reset on every start; the earlier "busy follows the committed state"
patch is gone, see PROVENANCE). The
patched jt6295 files are identical in the 1945k III, Tecmo 16, Dooyong and
Hyper Duel cores; see `jt6295/PROVENANCE.md` for every patch and its
evidence. Re-verification of this core with patches 1 and 2 added:
docs/m3_findings.md section 9.
