# ---------------------------------------------------------------- M3
# Sound (t16_snd: T80, jt51, jt6295) against MAME. Included by sim/Makefile.
#   make m3-oracle   MAME runs with the sound event log (t16_oracle.lua
#                    SNDLOG=1) and -wavwrite at 48 kHz, same inputs as M0
#   make m3-boot     the same runs in the core (tb_sys +snd +wav)
#   make m3-compare  event streams (m3/align_snd.py), sound RAM against the
#                    M2 oracle dumps every 40 frames (m3/compare_sndram.py)
#                    and levels (m3/compare_audio.py) for every run
#   make m3          all three
# <run>:<set>:<machine>:<frames>:<dsw2>:<play inputs or empty>
M3RUNS := fs_attract:fstarfrc:0:3601:00FF: fs_play:fstarfrc:0:3601:00FF:fstarfrc_6000 \
  riot_attract:riot:1:3601:00FC: riot_play:riot:1:3601:00FC:riot_4700 \
  ginkun_attract:ginkun:2:3601:00FF:
M3OUT  := build/m3/gate
M3JOBS ?= 5

m3-oracle:
	@for r in $(M3RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); nf=$$(echo $$r | cut -d: -f4); \
	  pl=$$(echo $$r | cut -d: -f6); inp=""; \
	  [ -n "$$pl" ] && inp="$$($(PY) ../tools/play_inputs.py $${pl%_*} 600 $${pl#*_})"; \
	  RT_TAG=m3_$$run DUMP_DIR=$(OUT)/m3_$$run TOTAL=$$((nf - 1)) SNDLOG=1 NO_SNAP=1 NO_DUMP=1 INPUTS="$$inp" \
	    $(RUN) $$set $(ORACLE) -wavwrite $(CURDIR)/$(OUT)/m3_$$run.wav -samplerate 48000 > $(OUT)/m3_$$run.log 2>&1 & \
	done; wait
	@for r in $(M3RUNS); do run=$$(echo $$r | cut -d: -f1); \
	  test -s $(OUT)/m3_$$run/summary.txt || { echo "m3 oracle run $$run did not finish"; exit 1; }; done

m3-boot: $(M2BIN)
	@for r in $(M3RUNS); do \
	  run=$$(echo $$r | cut -d: -f1); set=$$(echo $$r | cut -d: -f2); mc=$$(echo $$r | cut -d: -f3); \
	  nf=$$(echo $$r | cut -d: -f4); d2=$$(echo $$r | cut -d: -f5); o=$(M3OUT)/$$run; \
	  rm -rf $$o && mkdir -p $$o; \
	  ls $(OUT)/m2ram_$$run/ram | sed -n 's/^0*\([0-9][0-9]*\)\.snd$$/\1/p' | sort -n | awk -v n=$$nf '$$1 < n' | awk 'NR % 5 == 1' > $$o/cap.txt; \
	  inp=""; [ -s $(OUT)/m3_$$run/inputs.csv ] && [ $$(wc -l < $(OUT)/m3_$$run/inputs.csv) -gt 1 ] && inp="+inputs=$(OUT)/m3_$$run/inputs.csv"; \
	  echo "$(M2BIN) +sdram=build/regions/$$set/sdram.bin +machine=$$mc +dsw1=00FF +dsw2=$$d2 +frames=$$nf $$inp +cap=$$o/cap.txt +out=$$o +snd=$$o/snd.csv +wav=$$o/audio.raw > $$o/run.log 2>&1"; \
	done | tr '\n' '\0' | xargs -0 -n 1 -P $(M3JOBS) sh -c

m3-compare:
	@for r in $(M3RUNS); do run=$$(echo $$r | cut -d: -f1); \
	  echo "== $$run"; tail -n 1 $(M3OUT)/$$run/run.log; \
	  $(PY) m3/align_snd.py $(M3OUT)/$$run/snd.csv $(OUT)/m3_$$run/sndlog.csv --kinds LYOIN --show 0 --maxdt; \
	  $(PY) m3/compare_sndram.py $(M3OUT)/$$run $(OUT)/m2ram_$$run/ram; \
	  $(PY) m3/compare_audio.py $(M3OUT)/$$run/audio.raw $(OUT)/m3_$$run.wav; \
	done

m3: m3-oracle m3-boot m3-compare
