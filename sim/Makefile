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

.PHONY: roms-check regions mame-regions oracle oracle-verify analyze m0 clean-out m1 m1-snapram m1-verify-latch m1-build m1-verify m1-synth m1-midscan m1-capacity m1-vislog

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
