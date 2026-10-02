# jtgaiden (reference only, not vendored)

Examined for reuse in M1 (2026-10-02): jotego/jtcores master
b672aca509474559def2f6caec51fcd52cceee62 (cores/gaiden/hdl last changed in
d318c657cf3180e0e7b1597de5abe66041b76477), files `jtgaiden_obj.v`,
`jtgaiden_objscan.v`, `jtgaiden_colmix.v`, `jtgaiden_priority.v`,
`jtgaiden_blender.v`. Licence: GPL-3.0-or-later (SPDX headers), compatible
with this core.

Decision: not reused; the core's renderer is new RTL written from MAME's
tecmo16 / tecmo_spr / tecmo_mix sources and checked against MAME frame by
frame. Reasons and the comparison are in docs/m1_findings.md section 3.
No jtgaiden file is part of this repository.
