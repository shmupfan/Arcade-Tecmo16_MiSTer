# Releases

Released bitstreams and MRA files, in the MiSTer-devel arcade layout.

Copy `Arcade-Tecmo16_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`, the
MRA files to `/media/fat/_Arcade/`, and the ROM sets (MAME 0.288/0.289
naming) to `/media/fat/games/mame/`.

Alternative versions live in `_alternatives/_Final Star Force/` and
`_alternatives/_Riot/` and are copied to the same folders under
`/media/fat/_Arcade/_alternatives/`.

| File | md5 | Notes |
|------|-----|-------|
| `Arcade-Tecmo16_20261004.rbf` | `11ec0adf355dfe3297811e62d2c5d290` | Final Star Force (four sets), Riot (two sets), Ganbare Ginkun. Updated the same day (first build `ea8e2e65a98e991cf8510ce646e156ff`): the YM2151 now resets properly (its clock enable runs during reset), so an OSD reset no longer keeps the previous sound state; power-on audio unchanged. |

Every released RBF passed, in order: frame replay against MAME for every
set (video pixel-exact), full-system boots against MAME from power-on, a
sound comparison against MAME, a board-level simulation through the MRA
stream and the SDRAM model, a clean Quartus timing summary (every clock
non-negative), and an md5-verified deploy.
