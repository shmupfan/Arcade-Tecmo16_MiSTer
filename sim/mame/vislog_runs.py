#!/usr/bin/env python3
"""M1 mid-scan input: rerun every M0 capture with VISLOG=1 (no frame dumps)
into mame/out/vislog/<run>/ with the same frames, inputs and DIP fields as
`make oracle` (keep the two in step), each run in its own MAME runtime dir.
Then check the rerun executed identically to the M0 capture (frames.csv,
the per-frame scroll, flip and IRQ trace, must be byte-identical).

Usage (from sim/): python3 mame/vislog_runs.py [--jobs N]
"""
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SIM = Path(__file__).resolve().parent.parent
OUT = SIM / "mame" / "out"


def inputs(setname, a, b):
    return subprocess.run([sys.executable, str(SIM.parent / "tools" / "play_inputs.py"), setname, str(a), str(b)],
                          capture_output=True, text=True, check=True).stdout.strip()


RUNS = [
    ("fs_attract", "fstarfrc", "1-12000/8,4600-5199", "", ""),
    ("fs_play", "fstarfrc", "700-6000/4", inputs("fstarfrc", 600, 6000), ""),
    ("riot_attract", "riot", "1-12000/8,2000-2599", "", ""),
    ("riot_play", "riot", "700-4700/4", inputs("riot", 600, 4700), ""),
    ("ginkun_attract", "ginkun", "1-12000/8,3000-3599", "", ""),
    ("fs_flip", "fstarfrc", "1-6000/20", "", "DSW1:Flip Screen:0"),
    ("riot_flip", "riot", "1-6000/20", "", "DSW2:Flip Screen:0"),
    ("ginkun_flip", "ginkun", "1-6000/20", "", "DSW2:Flip Screen:0"),
] + [(f"clone_{s}", s, "30-9000/30", "", "") for s in ("fstarfrcj", "fstarfrcja", "fstarfrcw", "riotw")]


def one(r):
    run, setname, frames, inp, fields = r
    d = OUT / "vislog" / run
    if d.exists():
        subprocess.run(["rm", "-rf", str(d)], check=True)
    env = dict(os.environ, RT_TAG=f"vislog_{run}", DUMP_DIR=str(d), DUMP_FRAMES=frames, INPUTS=inp,
               FIELDS=fields, VISLOG="1", NO_DUMP="1", NO_SNAP="1")
    with open(OUT / "vislog" / f"{run}.log", "w") as log:
        rc = subprocess.run([str(SIM / "mame" / "run_mame.sh"), setname, str(SIM / "mame" / "t16_oracle.lua")],
                            cwd=SIM, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    same = (d / "frames.csv").read_bytes() == (OUT / run / "frames.csv").read_bytes() if (d / "frames.csv").exists() else False
    rows = sum(1 for _ in open(d / "vislog.csv")) - 1 if (d / "vislog.csv").exists() else -1
    return run, rc, same, rows


def main(argv):
    jobs = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else 6
    (OUT / "vislog").mkdir(parents=True, exist_ok=True)
    bad = 0
    with ThreadPoolExecutor(jobs) as ex:
        for run, rc, same, rows in ex.map(one, RUNS):
            ok = rc == 0 and same and rows >= 0
            bad += not ok
            print(f"{run}: rc {rc}, frames.csv identical to M0 run: {same}, vislog rows {rows}", flush=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
