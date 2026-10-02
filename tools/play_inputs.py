#!/usr/bin/env python3
"""Print an INPUTS string for t16_oracle.lua that plays a real game: coin,
start, then fire held while the player sweeps left/right and up/down, with
the second button every ~12 s. Deterministic, so captures are reproducible.

Usage: tools/play_inputs.py <fstarfrc|riot> <start_frame> <end_frame>
"""
import sys


def main(argv):
    game, start, end = argv[0], int(argv[1]), int(argv[2])
    fire = "EXTRA:P1 Button 1" if game == "riot" else "P1_P2:P1 Button 1"
    second = "P1_P2:P1 Button 2"
    ev = []

    def press(f, field, dur=6):
        ev.append(f"{f}:{field}:1")
        ev.append(f"{f + dur}:{field}:0")

    press(start, "P1_P2:Coin 1")
    press(start + 60, "P1_P2:Coin 1")
    press(start + 120, "P1_P2:1 Player Start")
    f0 = start + 300
    ev.append(f"{f0}:{fire}:1")
    dirs = ["P1 Left", "P1 Up", "P1 Right", "P1 Down"]
    f, i = f0 + 30, 0
    while f < end - 60:
        d = dirs[i % len(dirs)]
        ev.append(f"{f}:P1_P2:{d}:1")
        ev.append(f"{f + 45}:P1_P2:{d}:0")
        if i % 12 == 11:
            press(f + 50, second)
        if i % 30 == 29:   # coin + start again in case the game ended
            press(f + 52, "P1_P2:Coin 1")
            press(f + 70, "P1_P2:1 Player Start")
        f += 60
        i += 1
    print(";".join(ev))


if __name__ == "__main__":
    main(sys.argv[1:])
