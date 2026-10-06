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
| `Arcade-Tecmo16_20261006.rbf` | `6509126f54bfe21b4589c16487cd295f` | Final Star Force (four sets), Riot (two sets), Ganbare Ginkun. Stable pixels on direct video (6 MHz, 384 x 264 raster, a whole number of clocks per pixel); vertical sync on the horizontal sync edge, so composite sync no longer disturbs the top of a CRT picture; new OSD options CRT H Position, CRT V Position and Flip Screen (Final Star Force). Replaces `Arcade-Tecmo16_20261004.rbf` (`11ec0adf355dfe3297811e62d2c5d290`). |

Every released RBF passed, in order: frame replay against MAME for every
set (video pixel-exact), full-system boots against MAME from power-on, a
sound comparison against MAME, a board-level simulation through the MRA
stream and the SDRAM model, a clean Quartus timing summary (every clock
non-negative), and an md5-verified deploy.
