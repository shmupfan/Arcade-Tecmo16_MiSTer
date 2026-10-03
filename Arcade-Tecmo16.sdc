derive_pll_clocks
derive_clock_uncertainty

# --------------------------------------------------------------------------
# Multicycle paths inside clock-enabled cores (pattern and rationale from the
# Hyper Duel, Dooyong and 1945k III cores). The 96 MHz system clock drives
# everything, but these only advance on enables several clocks apart:
#   fx68k    : enPhi1 / enPhi2 at 2 x 12 MHz, a phase every 4 clocks
#   T80 sound: 4 MHz enable, every 24 clocks
#   jt51     : 4 MHz enable (cen), every 24 clocks
#   jt6295   : 1 MHz enable, every 96 clocks
# Two cycles is conservative. Only intra-core paths are relaxed; paths into
# and out of the cores (bus decode, RAMs, the SDRAM port) stay single-cycle.
# Instance names: t16_board.u_sys.{u_m68k, u_snd.u_cpu, u_snd.u_ym,
# u_snd.u_oki}.
# --------------------------------------------------------------------------
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|u_sys|u_m68k|*}] -to [get_registers {emu|board|u_sys|u_m68k|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|u_sys|u_m68k|*}] -to [get_registers {emu|board|u_sys|u_m68k|*}]

set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|u_sys|u_snd|u_cpu|*}] -to [get_registers {emu|board|u_sys|u_snd|u_cpu|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|u_sys|u_snd|u_cpu|*}] -to [get_registers {emu|board|u_sys|u_snd|u_cpu|*}]

set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|*u_ym|*}] -to [get_registers {emu|board|*u_ym|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|*u_ym|*}] -to [get_registers {emu|board|*u_ym|*}]

set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|*u_oki|*}] -to [get_registers {emu|board|*u_oki|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|*u_oki|*}] -to [get_registers {emu|board|*u_oki|*}]

# The machine byte and the DIP switches are loaded from the MRA while the
# core is held in reset and are static during play.
set_false_path -from [get_registers {emu|board|machine*}]
set_false_path -from [get_registers {emu|board|dsw0*}]
set_false_path -from [get_registers {emu|board|dsw1*}]
