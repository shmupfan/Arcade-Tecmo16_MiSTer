# Tecmo 16 (Final Star Force / Riot / Ganbare Ginkun) simulation and
# oracle harness.
#
# M0 targets (MAME 0.288 on PATH, or MAME=...; ROM zips in ../roms):
#   make roms-check      CRC/SHA1/size of all 7 sets vs the table generated
#                        from reference/mame/tecmo16.cpp
#   make regions         rebuild every MAME region + SDRAM image (build/regions)
#   make mame-regions    dump regions from MAME for all 7 sets and compare
#                        byte for byte with `make regions`
#   make oracle          all captures below (runs in parallel)
#   make oracle-verify   Python renderer vs MAME on every captured frame
#   make analyze         write-log and sprite summaries of every capture
#   make m0              everything above, in order
#
# M1 targets (Verilator; need `make regions` and the M0 captures):
#   make m1-build        build the t16_video frame-replay harness (LIVE, the
#                        default build) and the LATCH variant
#   make m1-snapram      sprite list copy-before-write unit test (gate)
#   make m1-verify       RTL vs MAME on every M0 capture frame, all 7 sets (gate)
#   make m1-verify-latch the same with the LATCH build
#   make m1-synth        synthetic scenes vs t16_render.py (gate)
#   make m1-midscan      replay every captured frame that has visible-scan
#                        writes with those writes applied at their beam
#                        position; classify each difference from MAME (gate:
#                        every differing frame explained)
#   make m1-capacity     sprites-per-line probe (not a gate)
#   make m1              build, verify, synth, midscan
#
# Every MAME run starts from a wiped cfg/nvram directory (mame/run_mame.sh),
# so captures are reproducible from power-on. Output lands in mame/out
# (gitignored, about 3 GB with the default plan).

PY      ?= python3
MAME    ?= mame
export MAME
OUT     := mame/out
RUN     := mame/run_mame.sh
ORACLE  := mame/t16_oracle.lua
ALLSETS := fstarfrc fstarfrcj fstarfrcja fstarfrcw riot riotw ginkun

# Capture plan (frame = MAME frame notifier count, 59.17 Hz).
# fstarfrc attract loop is about 2,000 frames (title, stage demo, a
# different stage each pass, "Recycle it" / "Winners don't use drugs"
# screens); riot about 5,200 (intro, title, city demo, history book);
# ginkun from the survey. The dense windows hold busy demo play.
FS_ATTRACT   := 1-12000/8,4600-5199
FS_PLAY      := 700-6000/4
RIOT_ATTRACT := 1-12000/8,2000-2599
RIOT_PLAY    := 700-4700/4
GK_ATTRACT   := 1-12000/8,3000-3599
FLIP_FRAMES  := 1-6000/20
CLONE_FRAMES := 30-9000/30
CLONES       := fstarfrcj fstarfrcja fstarfrcw riotw
RUNS := fs_attract fs_play riot_attract riot_play ginkun_attract \
        fs_flip riot_flip ginkun_flip $(addprefix clone_,$(CLONES))

.PHONY: roms-check regions mame-regions oracle oracle-verify analyze m0 clean-out m1 m1-snapram m1-verify-latch m1-build m1-verify m1-synth m1-midscan m1-capacity m1-vislog m2-build m2-oracle m2-stacklow m2-boot m2-compare m2-soak m2-promlat m2-pause m2-hw

roms-check:
	$(PY) ../tools/check_roms.py

regions:
	$(PY) ../tools/build_regions.py

mame-regions: regions
	@for s in $(ALLSETS); do \
	  DUMP_DIR=$(OUT)/regions/$$s $(RUN) $$s mame/dump_regions.lua -seconds_to_run 5 >/dev/null 2>&1 \
	    || echo "MAME failed on $$s"; \
	done
	$(PY) ../tools/compare_regions.py $(ALLSETS)

oracle:
	mkdir -p $(OUT); rm -rf $(addprefix $(OUT)/,$(RUNS))
	DUMP_DIR=$(OUT)/fs_attract DUMP_FRAMES=$(FS_ATTRACT) $(RUN) fstarfrc $(ORACLE) >$(OUT)/fs_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/fs_play DUMP_FRAMES=$(FS_PLAY) INPUTS="$$($(PY) ../tools/play_inputs.py fstarfrc 600 6000)" \
	  $(RUN) fstarfrc $(ORACLE) >$(OUT)/fs_play.log 2>&1 & \
	DUMP_DIR=$(OUT)/riot_attract DUMP_FRAMES=$(RIOT_ATTRACT) $(RUN) riot $(ORACLE) >$(OUT)/riot_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/riot_play DUMP_FRAMES=$(RIOT_PLAY) INPUTS="$$($(PY) ../tools/play_inputs.py riot 600 4700)" \
	  $(RUN) riot $(ORACLE) >$(OUT)/riot_play.log 2>&1 & \
	DUMP_DIR=$(OUT)/ginkun_attract DUMP_FRAMES=$(GK_ATTRACT) $(RUN) ginkun $(ORACLE) >$(OUT)/ginkun_attract.log 2>&1 & \
	DUMP_DIR=$(OUT)/fs_flip DUMP_FRAMES=$(FLIP_FRAMES) FIELDS="DSW1:Flip Screen:0" \
	  $(RUN) fstarfrc $(ORACLE) >$(OUT)/fs_flip.log 2>&1 & \
	DUMP_DIR=$(OUT)/riot_flip DUMP_FRAMES=$(FLIP_FRAMES) FIELDS="DSW2:Flip Screen:0" \
	  $(RUN) riot $(ORACLE) >$(OUT)/riot_flip.log 2>&1 & \
	DUMP_DIR=$(OUT)/ginkun_flip DUMP_FRAMES=$(FLIP_FRAMES) FIELDS="DSW2:Flip Screen:0" \
	  $(RUN) ginkun $(ORACLE) >$(OUT)/ginkun_flip.log 2>&1 & \
	for s in $(CLONES); do \
	  DUMP_DIR=$(OUT)/clone_$$s DUMP_FRAMES=$(CLONE_FRAMES) $(RUN) $$s $(ORACLE) >$(OUT)/clone_$$s.log 2>&1 & \
	done; wait
	@for r in $(RUNS); do test -s $(OUT)/$$r/summary.txt || { echo "run $$r did not finish"; exit 1; }; done

oracle-verify:
	@rc=0; for r in $(RUNS); do \
	  ( echo "== $$r"; $(PY) oracle/compare_frames.py $(OUT)/$$r --quiet ) > $(OUT)/verify_$$r.txt 2>&1 & \
	done; wait; for r in $(RUNS); do cat $(OUT)/verify_$$r.txt; tail -1 $(OUT)/verify_$$r.txt | grep -q "^\([0-9]*\)/\1 frames" || rc=1; done; exit $$rc

analyze:
	$(PY) ../tools/analyze_writes.py $(addprefix $(OUT)/,$(RUNS))

m0: roms-check mame-regions oracle oracle-verify analyze

clean-out:
	rm -rf $(OUT) build

# ---------------------------------------------------------------- M1
VERILATOR ?= verilator
RTL       := ../rtl/t16_video.sv ../rtl/t16_snapram.sv ../rtl/t16_dpram.sv ../rtl/t16_fifo.sv
M1BIN     := build/m1/obj_dir/Vt16_video
M1LBIN    := build/m1_latch/obj_dir/Vt16_video
VFLAGS    := --cc --exe --build -O3 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND \
             -Wno-WIDTHTRUNC --top-module t16_video -CFLAGS -O2
M1RUNS    := $(addprefix $(OUT)/,$(RUNS))
JOBS      ?= 6

$(M1BIN): $(RTL) m1/tb_video.cpp
	mkdir -p build/m1
	$(VERILATOR) $(VFLAGS) -Mdir build/m1/obj_dir $(RTL) m1/tb_video.cpp

$(M1LBIN): $(RTL) m1/tb_video.cpp
	mkdir -p build/m1_latch
	$(VERILATOR) $(VFLAGS) -GLATCH=1 -Mdir build/m1_latch/obj_dir $(RTL) m1/tb_video.cpp

m1-build: $(M1BIN) $(M1LBIN)

m1-verify: $(M1BIN)
	$(PY) m1/replay.py $(M1RUNS) --jobs $(JOBS) --quiet

m1-verify-latch: $(M1LBIN)
	$(PY) m1/replay.py $(M1RUNS) --jobs $(JOBS) --quiet --latch

m1-synth: $(M1BIN)
	$(PY) m1/make_scenes.py build/m1/scenes
	$(PY) m1/replay.py build/m1/scenes/* --jobs $(JOBS) --quiet

m1-vislog:
	$(PY) mame/vislog_runs.py --jobs $(JOBS)

m1-midscan: $(M1BIN) $(M1LBIN)
	$(PY) m1/midscan.py $(RUNS) --jobs $(JOBS)

SNAPBIN   := build/m1_snap/obj_dir/Vt16_snapram
$(SNAPBIN): ../rtl/t16_snapram.sv ../rtl/t16_dpram.sv m1/tb_snapram.cpp
	mkdir -p build/m1_snap
	$(VERILATOR) --cc --exe --build -O3 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --top-module t16_snapram \
	  -GMODE=2 -GAW=11 -Mdir build/m1_snap/obj_dir ../rtl/t16_snapram.sv ../rtl/t16_dpram.sv m1/tb_snapram.cpp

m1-snapram: $(SNAPBIN)
	$(SNAPBIN) +rounds=40 +gap=32 +seed=1
	$(SNAPBIN) +rounds=40 +gap=8 +seed=2

m1-capacity: $(M1BIN)
	$(PY) m1/capacity.py

m1: m1-build m1-snapram m1-verify m1-verify-latch m1-synth m1-midscan

# ---------------------------------------------------------------- M2
# Full system (t16_sys: fx68k, T80, jt51, jt6295, t16_video LIVE) at the
# hardware clock, 96 MHz. Two builds:
#   m2      MAME parity raster (the gate): V_TOTAL 256 and a pixel enable of
#           47336/781250, exactly MAME's 59.17 Hz frame of 256 lines
#           (t16:679-681) drawn as 384 pixel periods per line; IRQ5 held
#           96,000 clocks = MAME's 1000 us vblank (t16:680)
#   m2_hw   the M1 raster (6 MHz, 384 x 264, MAME's TODO guess t16:20) with
#           the same 1000 us IRQ5: not MAME-comparable frame for frame; run
#           to measure what the raster choice changes (m2_findings, R3)
# Program ROM model: ok 9 clocks after the request (the M4 SDRAM worst case),
# garbage before; graphics ROM model as M1 (one read per 8 clocks, latency 9).
FX68K   := ../rtl/vendor/fx68k
M2RTL   := ../rtl/vendor/t80/T80s.v $(wildcard ../rtl/vendor/jt51/hdl/jt51*.v) \
  $(wildcard ../rtl/vendor/jt6295/hdl/*.v) $(FX68K)/fx68k.sv $(FX68K)/fx68kAlu.sv $(FX68K)/uaddrPla.sv \
  $(RTL) ../rtl/t16_snd.sv ../rtl/t16_sys.sv
M2VFLAGS := --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --x-assign fast --x-initial fast \
  --top-module t16_sys -I../rtl/vendor/jt51/hdl -CFLAGS "-O3 -march=native" -j 4
M2BIN   := build/m2/obj_dir/Vt16_sys
M2HBIN  := build/m2_hw/obj_dir/Vt16_sys
M2OUT   := build/m2/gate
M2PAR   := -GV_TOTAL=256 -GPIX_NUM=47336 -GPIX_DEN=781250 -GIRQ_HOLD=96000

$(M2BIN): $(M2RTL) m2/tb_sys.cpp
	mkdir -p build/m2
	$(VERILATOR) $(M2VFLAGS) -Mdir build/m2/obj_dir $(M2PAR) $(M2PARAMS) $(M2RTL) m2/tb_sys.cpp
	cp -f $(FX68K)/microrom.mem $(FX68K)/nanorom.mem .   # fx68k $$readmemb, relative to the run directory

$(M2HBIN): $(M2RTL) m2/tb_sys.cpp
	mkdir -p build/m2_hw
	$(VERILATOR) $(M2VFLAGS) -Mdir build/m2_hw/obj_dir $(M2RTL) m2/tb_sys.cpp
	cp -f $(FX68K)/microrom.mem $(FX68K)/nanorom.mem .

m2-build: $(M2BIN) $(M2HBIN)

# MAME runs with RAM dumps and the port read log (t16_oracle.lua MAINRAM=1),
# same frames and inputs as the M0 captures, no video dumps (the M0 capture
# has them; MAME runs are deterministic from power-on).
M2MRUNS := fs_attract:fstarfrc:$(FS_ATTRACT): fs_play:fstarfrc:$(FS_PLAY):fstarfrc_6000 \
  riot_attract:riot:$(RIOT_ATTRACT): riot_play:riot:$(RIOT_PLAY):riot_4700 \
  ginkun_attract:ginkun:$(GK_ATTRACT): clone_fstarfrcw:fstarfrcw:$(CLONE_FRAMES): \
  clone_riotw:riotw:$(CLONE_FRAMES):
m2-oracle:
	@for r in $(M2MRUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); fr=$$(echo $$r | cut -d: -f3); \
	  pl=$$(echo $$r | cut -d: -f4); inp=""; \
	  [ -n "$$pl" ] && inp="$$($(PY) ../tools/play_inputs.py $${pl%_*} 600 $${pl#*_})"; \
	  RT_TAG=m2_$$run DUMP_DIR=$(OUT)/m2ram_$$run DUMP_FRAMES=$$fr MAINRAM=1 NO_SNAP=1 NO_DUMP=1 INPUTS="$$inp" \
	    $(RUN) $$set $(ORACLE) > $(OUT)/m2ram_$$run.log 2>&1 & \
	done; wait
	@for r in $(M2MRUNS); do run=$$(echo $$r | cut -d: -f1); \
	  test -s $(OUT)/m2ram_$$run/summary.txt || { echo "m2 oracle run $$run did not finish"; exit 1; }; done

# The 68000 stack's low-water mark per capture (t16_oracle.lua STACKLOW=1):
# m2/compare.py treats stack words as interrupted context (m2_findings 5).
m2-stacklow:
	@for r in $(M2MRUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); fr=$$(echo $$r | cut -d: -f3); \
	  pl=$$(echo $$r | cut -d: -f4); inp=""; tot=$$(echo $$fr | tr ',' '\n' | sed 's/.*-//; s/\/.*//' | sort -n | tail -1); \
	  [ -n "$$pl" ] && inp="$$($(PY) ../tools/play_inputs.py $${pl%_*} 600 $${pl#*_})"; \
	  RT_TAG=sl_$$run DUMP_DIR=$(OUT)/stacklow_$$run TOTAL=$$tot STACKLOW=1 NO_SNAP=1 NO_DUMP=1 INPUTS="$$inp" \
	    $(RUN) $$set $(ORACLE) > $(OUT)/stacklow_$$run.log 2>&1 & \
	done; wait
	@grep -H "low-water" $(OUT)/stacklow_*/summary.txt

# Boot runs from power-on through each M0 capture: <run>:<set>:<machine>:<frames>:<dsw1>:<dsw2>
# fs_attract runs 20,000 frames: the comparison covers the 12,000-frame
# capture and the whole run is the soak (gate counters at 0 after boot).
M2RUNS := fs_attract:fstarfrc:0:20001:00FF:00FF fs_play:fstarfrc:0:6001:00FF:00FF \
  riot_attract:riot:1:12001:00FF:00FC riot_play:riot:1:4701:00FF:00FC \
  ginkun_attract:ginkun:2:12001:00FF:00FF clone_fstarfrcw:fstarfrcw:0:9001:00FF:00FF
M2JOBS ?= 6
m2-boot: $(M2BIN)
	@for r in $(M2RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); mc=$$(echo $$r | cut -d: -f3); \
	  nf=$$(echo $$r | cut -d: -f4); d1=$$(echo $$r | cut -d: -f5); d2=$$(echo $$r | cut -d: -f6); o=$(M2OUT)/$$run; \
	  rm -rf $$o && mkdir -p $$o; \
	  ls $(OUT)/$$run/frames | sed 's/^0*//' | awk '{print $$1; print $$1-1}' | sort -n | uniq | awk '$$1>0' > $$o/cap.txt; \
	  inp=""; [ $$(wc -l < $(OUT)/$$run/inputs.csv) -gt 1 ] && inp="+inputs=$(OUT)/$$run/inputs.csv"; \
	  echo "$(M2BIN) +sdram=build/regions/$$set/sdram.bin +machine=$$mc +dsw1=$$d1 +dsw2=$$d2 +frames=$$nf $$inp +cap=$$o/cap.txt +out=$$o +io=$$o/io.txt +ftrace=$$o/ftrace.txt +events=$$o/events.txt > $$o/run.log 2>&1"; \
	done | tr '\n' '\0' | xargs -0 -n 1 -P $(M2JOBS) sh -c
	$(MAKE) m2-compare

m2-compare:
	@rc=0; for r in $(M2RUNS); do run=$$(echo $$r | cut -d: -f1); \
	  echo "== $$run"; tail -n 1 $(M2OUT)/$$run/run.log; \
	  $(PY) m2/compare.py $(M2OUT)/$$run $(OUT)/$$run $(OUT)/m2ram_$$run --quiet || rc=1; \
	done; exit $$rc

m2-soak: $(M2BIN)
	mkdir -p $(M2OUT)/soak && : > $(M2OUT)/soak/cap.txt
	$(M2BIN) +sdram=build/regions/fstarfrc/sdram.bin +machine=0 +frames=20000 \
	  +cap=$(M2OUT)/soak/cap.txt +out=$(M2OUT)/soak > $(M2OUT)/soak/run.log 2>&1; tail -n 1 $(M2OUT)/soak/run.log

# Program ROM latency margin (m2_findings): 300 frames of fstarfrc with the
# ROM answering at the bus limit (PROM_LIMIT = 17 clocks at 96 MHz) and one
# clock beyond it; the first must run with o_dbg_prom_late = 0 and the same
# I/O and IRQ trace as the 9-clock run, the second must count late reads.
m2-promlat: $(M2BIN)
	@for l in 9 17 18; do o=$(M2OUT)/promlat_$$l; rm -rf $$o; mkdir -p $$o; : > $$o/cap.txt; \
	  echo "$(M2BIN) +sdram=build/regions/fstarfrc/sdram.bin +machine=0 +frames=300 +promlat=$$l +cap=$$o/cap.txt +out=$$o +io=$$o/io.txt +ftrace=$$o/ftrace.txt > $$o/run.log 2>&1"; \
	done | tr '\n' '\0' | xargs -0 -n 1 -P 3 sh -c
	@for l in 9 17 18; do echo "promlat $$l: $$(tail -n 1 $(M2OUT)/promlat_$$l/run.log)"; done
	@cmp -s $(M2OUT)/promlat_9/io.txt $(M2OUT)/promlat_17/io.txt && cmp -s $(M2OUT)/promlat_9/ftrace.txt $(M2OUT)/promlat_17/ftrace.txt \
	  && echo "promlat 17: I/O and IRQ trace identical to promlat 9" || echo "promlat 17: TRACE DIFFERS"

# Pause: hold i_pause for 120 frames from vblank 700 of a fstarfrc boot;
# m2/pause_check.py checks the RAM stays frozen and the game resumes.
m2-pause: $(M2BIN)
	o=$(M2OUT)/pause; rm -rf $$o; mkdir -p $$o; seq 690 840 > $$o/cap.txt; \
	$(M2BIN) +sdram=build/regions/fstarfrc/sdram.bin +machine=0 +frames=900 +pause=700:120 \
	  +cap=$$o/cap.txt +out=$$o +ftrace=$$o/ftrace.txt > $$o/run.log 2>&1; tail -n 1 $$o/run.log
	$(PY) m2/pause_check.py $(M2OUT)/pause 700 120

# The M1 raster (6 MHz, 384 x 264) with MAME's 1000 us IRQ5: boots of each
# parent, IRQ5 entries per frame against MAME's distribution (m2_findings 7).
m2-hw: $(M2HBIN)
	@for r in fstarfrc:0:00FF riot:1:00FC ginkun:2:00FF; do s=$${r%%:*}; t=$${r#*:}; mc=$${t%%:*}; d2=$${t#*:}; \
	  o=build/m2_hw/$$s; rm -rf $$o; mkdir -p $$o; seq 2990 3000 > $$o/cap.txt; \
	  echo "$(M2HBIN) +sdram=build/regions/$$s/sdram.bin +machine=$$mc +dsw2=$$d2 +frames=3001 +cap=$$o/cap.txt +out=$$o +io=$$o/io.txt +ftrace=$$o/ftrace.txt +events=$$o/events.txt > $$o/run.log 2>&1"; \
	done | tr '\n' '\0' | xargs -0 -n 1 -P 3 sh -c
	$(PY) m2/hw_raster.py build/m2_hw $(OUT)

include m3.mk
