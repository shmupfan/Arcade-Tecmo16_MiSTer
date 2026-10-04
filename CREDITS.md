# Credits and third-party components

This core combines new RTL with proven open-source components. Every
third-party component retains its own license and copyright headers in
place; the combined work is distributed under GPL-3.0-or-later (see
LICENSE). Local modifications to vendored cores are documented in
`rtl/vendor/README.md`, `rtl/vendor/SOUND_PROVENANCE.md` and each
component's `PROVENANCE.md`.

## New work in this repository

- Video (`rtl/t16_video.sv`, `rtl/t16_fifo.sv`, `rtl/t16_dpram.sv`,
  `rtl/t16_snapram.sv`): line renderer for the three tile layers, the
  text layer and the sprite list, and the Tecmo colour mixer.
  GPL-3.0-or-later.
- System glue (`rtl/t16_sys.sv`), sound board (`rtl/t16_snd.sv`), SDRAM
  controller (`rtl/t16_sdram.sv`), board wrapper (`rtl/t16_board.sv`),
  MiSTer shell (`Arcade-Tecmo16.sv`), simulation and verification harness
  (`sim/`), tooling (`tools/`). GPL-3.0-or-later.

## Vendored cores (`rtl/vendor/`)

| Component | Author | License | Upstream |
|---|---|---|---|
| fx68k (68000, cycle-accurate) | Jorge Cwik | GPL-3.0 | https://github.com/ijor/fx68k |
| T80 (Z80) | Daniel Wallner, as maintained in jtframe | BSD-style (file headers) | https://github.com/jotego/jtcores |
| jt51 (YM2151) | Jose Tejada (@topapate / jotego) | GPL-3.0 | https://github.com/jotego/jt51 |
| jt6295 (OKI MSM6295) | Jose Tejada (@topapate / jotego) | GPL-3.0-or-later | https://github.com/jotego/jt6295 |

Local changes:

- fx68k carries the Verilator portability patches from the Hyper Duel
  core (no functional change; `rtl/vendor/fx68k/PROVENANCE.md`).
- T80 is unchanged; the core starts the Z80 with IX = IY = 0xFFFF, MAME's
  power-on state (`rtl/vendor/t80/PROVENANCE.md`).
- jt51 has a simulation-only timer option, off in the core
  (`rtl/vendor/SOUND_PROVENANCE.md`).
- jt6295 carries Hyper Duel's Quartus RAM-inference workaround and
  simulation-only Verilator annotations, neither changing behaviour, plus
  three behaviour fixes that match MAME's M6295 model: a phrase plays
  through the second nibble of its stop byte; a start command to a
  channel that is still playing is ignored; and the busy status is timed
  as the MSM6295 datasheet describes, a start never cancels a stop, and
  the decoder resets on every start (`rtl/vendor/jt6295/PROVENANCE.md`).
  The same patched jt6295 is used in the shmupfan 1945k III and Dooyong
  cores and in Hyper Duel.

The sound comes from Jose Tejada's jt51 and jt6295. If you enjoy this
core, consider supporting him: https://www.patreon.com/jotego

## MiSTer framework (`sys/`)

The MiSTer template and framework files are copyright their respective
authors (Sorgelig and MiSTer-devel contributors), GPL-2.0-or-later.
https://github.com/MiSTer-devel

## Reference material

- MAME's `tecmo/tecmo16.cpp` (copyright Hau and Nicola Salmoria) and the
  Tecmo sprite and mixer devices `tecmo_spr.cpp` and `tecmo_mix.cpp`
  (copyright David Haywood), all BSD-3-Clause, are vendored under
  `reference/mame/` as the behavioural documentation of record. This core
  would not exist without that work. https://github.com/mamedev/mame

## The games

The games are copyright Tecmo. This repository contains no game ROM data
in any form; the core loads a user-supplied MAME ROM set at runtime via
the MRA files.
