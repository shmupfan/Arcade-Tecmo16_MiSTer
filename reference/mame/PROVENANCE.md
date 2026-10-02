# MAME reference sources

Vendored from mamedev/mame master at commit
c4fc5eb7905d817a551370c25c32476474bdad6c (fetched 2026-10-02), BSD-3-Clause
(see each file's header). Behavioural reference only: nothing here is
compiled into the core.

| File | MAME path | Last changed upstream |
|---|---|---|
| tecmo16.cpp | src/mame/tecmo/tecmo16.cpp | 774a180df2 (2026-08-02) |
| tecmo_spr.cpp, tecmo_spr.h | src/mame/shared/tecmo_spr.* | 190fd35eb5 (2025-07-19), d066f16134 (2026-06-02) |
| tecmo_mix.cpp, tecmo_mix.h | src/mame/tecmo/tecmo_mix.* | e89ba4f5b5 (2022-08-24), d066f16134 (2026-06-02) |

The local oracle is MAME 0.288. Against tag mame0288 these files differ only
in device constructor signatures (default `clock = 0`, a palette/gfxinfo
convenience constructor, `SCREEN(config, m_screen)` without the raster type
argument): tecmo16.cpp 3 lines, tecmo_spr.h 4 lines, tecmo_mix.h 1 line;
tecmo_spr.cpp and tecmo_mix.cpp are identical. No behaviour differs.
