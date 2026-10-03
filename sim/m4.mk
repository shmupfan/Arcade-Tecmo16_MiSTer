# M4 targets (MiSTer board, SDRAM, MRA) for the Tecmo 16 core. Run from sim/
# with `make -f m4.mk <target>` (sim/Makefile can include it later).
#
#   make m4-mra          generate every MRA and prove each one rebuilds
#                        sdram.bin byte for byte (Main_MiSTer loader rules)
#   make m4-sdram        t16_sdram + SDRAM model: download fstarfrc's image
#                        through the ioctl port, then 68000 fetches (12 MHz
#                        bus cycles), graphics at full pressure and the OKI at
#                        once for 4M clocks; every word checked, CPU latency
#                        histogram (must stay <= 17 clocks, t16_sys
#                        PROM_LIMIT), refresh accounting; the model stops on
#                        any SDRAM timing violation
#   make m4-sdram-all    the same, 1M clocks, every set
#   make m4-lint         Verilator -Wall on t16_sdram, t16_board
#   make m4-lint-shell   the emu shell with the framework stubs
#   make m4-build        tb_board: t16_board + SDRAM model, everything through
#                        ioctl as on the MiSTer (MAME raster, the M2 gate's)
#   make m4-smoke        300 frames of each parent through the board,
#                        images at frames 100/200/300, gate counters
#
# sim/build/regions/<set>/sdram.bin comes from `make regions` (M0).

PY        ?= python3
VERILATOR ?= verilator
M4DIR     ?= build/m4
M4SETS    := fstarfrc fstarfrcj fstarfrcja fstarfrcw riot riotw ginkun
FX68K     := ../rtl/vendor/fx68k

M4SDRTL  := ../rtl/t16_sdram.sv m4/sdram_model.sv m4/tb_sdram.sv
M4SDBIN  := $(M4DIR)/sdram_obj/Vtb_sdram

.PHONY: m4-mra m4-sdram m4-sdram-all m4-sdram-build m4-lint m4-lint-shell m4-build m4-smoke

m4-mra:
	cd .. && $(PY) tools/make_mra.py

$(M4SDBIN): $(M4SDRTL) m4/tb_sdram.cpp
	$(VERILATOR) --cc --exe --build -j 4 -Wno-fatal -Wno-MULTIDRIVEN --top-module tb_sdram \
	  -Mdir $(M4DIR)/sdram_obj -o Vtb_sdram -CFLAGS -O2 $(M4SDRTL) m4/tb_sdram.cpp

m4-sdram-build: $(M4SDBIN)

m4-sdram: $(M4SDBIN)
	$(M4SDBIN) +sdram=build/regions/fstarfrc/sdram.bin +cycles=4000000 +seed=1 | tee $(M4DIR)/sdram_fstarfrc.log
	@grep -q '^PASS' $(M4DIR)/sdram_fstarfrc.log

m4-sdram-all: $(M4SDBIN)
	@rc=0; for s in $(M4SETS); do \
	  $(M4SDBIN) +sdram=build/regions/$$s/sdram.bin +cycles=1000000 +seed=7 > $(M4DIR)/sdram_$$s.log; \
	  printf '%-11s ' $$s; tail -n 1 $(M4DIR)/sdram_$$s.log; \
	  grep -q '^PASS' $(M4DIR)/sdram_$$s.log || rc=1; \
	done; exit $$rc

M4BRTL := ../rtl/vendor/t80/T80s.v $(wildcard ../rtl/vendor/jt51/hdl/jt51*.v) \
          $(wildcard ../rtl/vendor/jt6295/hdl/*.v) $(FX68K)/fx68k.sv $(FX68K)/fx68kAlu.sv $(FX68K)/uaddrPla.sv \
          ../rtl/t16_video.sv ../rtl/t16_snapram.sv ../rtl/t16_dpram.sv ../rtl/t16_fifo.sv \
          ../rtl/t16_snd.sv ../rtl/t16_sys.sv ../rtl/t16_sdram.sv ../rtl/t16_board.sv

m4-lint:
	$(VERILATOR) --lint-only -Wall -Wno-MULTIDRIVEN --top-module t16_sdram ../rtl/t16_sdram.sv
	$(VERILATOR) --lint-only -Wall -Wno-MULTIDRIVEN -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM \
	  -I$(FX68K) -I../rtl/vendor/jt6295/hdl -I../rtl/vendor/jt51/hdl --top-module t16_board $(M4BRTL)

m4-lint-shell:
	$(VERILATOR) --lint-only -Wno-fatal -Wno-TIMESCALEMOD -DLINT_STUBS -DMISTER_FB=1 -I.. -I../sys \
	  -I$(FX68K) -I../rtl/vendor/jt6295/hdl -I../rtl/vendor/jt51/hdl --top-module emu \
	  m4/lint_stubs.sv ../sys/math.sv ../sys/video_freak.sv ../Arcade-Tecmo16.sv $(M4BRTL)

M4BBIN := $(M4DIR)/board_obj/Vtb_board

$(M4BBIN): $(M4BRTL) m4/sdram_model.sv m4/tb_board.sv m4/tb_board.cpp
	$(VERILATOR) --cc --exe --build -j 4 -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
	  --x-assign fast --x-initial fast --top-module tb_board \
	  -I$(FX68K) -I../rtl/vendor/jt6295/hdl -I../rtl/vendor/jt51/hdl \
	  -Mdir $(M4DIR)/board_obj -o Vtb_board -CFLAGS "-O3 -march=native" \
	  $(M4BRTL) m4/sdram_model.sv m4/tb_board.sv m4/tb_board.cpp
	cp -f $(FX68K)/microrom.mem $(FX68K)/nanorom.mem .   # fx68k $$readmemb, relative to the run directory

m4-build: $(M4BBIN)

M4SMOKE := fstarfrc:0 riot:1 ginkun:2
m4-smoke: $(M4BBIN)
	@for r in $(M4SMOKE); do s=$${r%%:*}; m=$${r##*:}; o=$(M4DIR)/smoke_$$s; \
	  rm -rf $$o && mkdir -p $$o && printf '100\n200\n300\n' > $$o/cap.txt; \
	  $(M4BBIN) +sdram=build/regions/$$s/sdram.bin +machine=$$m +frames=301 +cap=$$o/cap.txt +out=$$o \
	    +io=$$o/io.txt > $$o/run.log 2>&1 & \
	done; wait
	@for r in $(M4SMOKE); do s=$${r%%:*}; printf '%-9s ' $$s; tail -n 1 $(M4DIR)/smoke_$$s/run.log; done
