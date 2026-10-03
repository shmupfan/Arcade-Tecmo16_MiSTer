project_open Arcade-Tecmo16
create_timing_netlist
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -to_clock $clk -npaths 400 -detail summary -file paths_setup.txt
report_timing -setup -to_clock $clk -npaths 3 -detail full_path -file paths_worst.txt
report_timing -hold -to_clock $clk -npaths 20 -detail summary -file paths_hold.txt
project_close
