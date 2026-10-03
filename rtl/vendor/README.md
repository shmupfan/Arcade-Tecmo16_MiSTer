# Vendored cores

Copied 2026-10-03 (M2) from the Dooyong MiSTer core
(`../dooyong-mister/rtl/vendor/`, repository commit
d0445799bba5e09097d14e5c65e3794cfedf2b79), byte for byte, where every one
of them runs on hardware. Each directory keeps the provenance file written
when the Dooyong core vendored it:

| Directory | Core | Licence | Provenance |
|---|---|---|---|
| `fx68k/` | 68000, Jorge Cwik | GPL-3.0 | `fx68k/PROVENANCE.md` (Verilator patches from Hyper Duel) |
| `t80/` | Z80, Daniel Wallner, as maintained in jtframe | BSD-style (file headers) | `t80/PROVENANCE.md` (IX = IY = 0xFFFF at reset, MAME's Z80 power-on state) |
| `jt51/` | YM2151, Jose Tejada | GPL-3.0 | `SOUND_PROVENANCE.md` (simulation-only `JT51_TIMER_EXACT` option, off) |
| `jt6295/` | OKI M6295, Jose Tejada | GPL-3.0 | `SOUND_PROVENANCE.md` (Quartus ramstyle attribute, Verilator public comments) |

Changed in this repository: `jt6295/hdl/jt6295_serial.v` (busy flags follow the committed channel state, a functional fix) and Verilator comments in `jt6295/hdl/jt6295.v`, both in `SOUND_PROVENANCE.md`; `rtl/t16_snd.sv` holds YM2151 writes until jt51's `cen_p1` (m3_findings 2).
