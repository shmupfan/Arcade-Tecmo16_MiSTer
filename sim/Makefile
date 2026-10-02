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

.PHONY: roms-check regions mame-regions oracle oracle-verify analyze m0 clean-out

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
