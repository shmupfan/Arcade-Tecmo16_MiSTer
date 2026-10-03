#!/usr/bin/env python3
"""M3: level and envelope of the core's stereo mix against MAME's WAV.

Ours: tb_sys.cpp +wav= (16-bit stereo pairs, 48 kHz, raw, from power-on of
the simulation; the first 0.683 ms are the reset and sound ROM download,
removed with --lead). MAME: -wavwrite of the same run, -samplerate 48000.
After removing the lead the two are on the same time axis (vblank 1 at the
same sample, sim/m3/align_snd.py); a residual lag is searched within +-20 ms
on 1 ms envelopes and reported. Then, per channel:
  - overall RMS ratio in dB (gate: within 1 dB),
  - RMS ratio per 10 s segment with sound in it,
  - correlation of the 20 ms RMS envelopes (the same events at the same
    time; jt51 and MAME's ymfm are not sample-identical, M6295 is close but
    MAME resamples, so waveforms are not compared sample by sample).

Usage: compare_audio.py OURS.raw MAME.wav [--lead MS] [--skip S] [--seg S]
"""
import argparse
import sys
import wave

import numpy as np


def env(x, win):
    n = len(x) // win
    return np.sqrt((x[:n * win].reshape(n, win) ** 2).mean(axis=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ours"); ap.add_argument("mame")
    ap.add_argument("--lead", type=float, default=0.683012)
    ap.add_argument("--skip", type=float, default=0.0)
    ap.add_argument("--seg", type=float, default=10.0)
    ap.add_argument("--band", type=float, default=3500.0,
                    help="also compare after a low-pass at this frequency (Hz); the gate uses this "
                         "band: above 3.8 kHz the core's raw M6295 output keeps its 7,576 Hz "
                         "sample-and-hold images, which MAME's resampler removes (m3_findings 5)")
    a = ap.parse_args()
    o = np.fromfile(a.ours, dtype="<i2").astype(np.float64).reshape(-1, 2)
    w = wave.open(a.mame)
    assert w.getsampwidth() == 2 and w.getframerate() == 48000, "MAME WAV must be 16-bit 48 kHz"
    ch = w.getnchannels()
    m = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64).reshape(-1, ch)
    if ch == 1:
        m = np.repeat(m, 2, axis=1)
    o = o[int(round(a.lead * 48)):]
    mono_o, mono_m = o.mean(axis=1), m.mean(axis=1)
    eo, em = env(mono_o, 48), env(mono_m, 48)
    n = min(len(eo), len(em))
    best = max(range(-20, 21), key=lambda k: np.dot(eo[max(0, k):n + min(0, k)], em[max(0, -k):n - max(0, k)]))
    lag = best * 48
    if lag >= 0:
        o = o[lag:]
    else:
        m = m[-lag:]
    n = min(len(o), len(m))
    s0 = int(a.skip * 48000)
    o, m = o[s0:n], m[s0:n]
    print(f"residual alignment: ours {best:+d} ms against MAME; compared {len(o) / 48000:.1f} s")
    def lp(x):
        X = np.fft.rfft(x, axis=0)
        f = np.fft.rfftfreq(len(x), 1 / 48000)
        X[f > a.band] = 0
        return np.fft.irfft(X, n=len(x), axis=0)
    full = {}
    for c in (0, 1):
        full[c] = 20 * np.log10(np.sqrt((o[:, c] ** 2).mean()) / np.sqrt((m[:, c] ** 2).mean()))
    print(f"full band: left {full[0]:+.2f} dB, right {full[1]:+.2f} dB (informational)")
    if a.band > 0:
        o, m = lp(o), lp(m)
        print(f"below {a.band:.0f} Hz (gate):")
    ok = True
    for c, name in ((0, "left"), (1, "right")):
        x, y = o[:, c], m[:, c]
        rx, ry = np.sqrt((x ** 2).mean()), np.sqrt((y ** 2).mean())
        db = 20 * np.log10(rx / ry) if ry > 0 and rx > 0 else float("nan")
        ea, eb = env(x, 960), env(y, 960)
        k = min(len(ea), len(eb))
        cc = np.corrcoef(ea[:k], eb[:k])[0, 1]
        print(f"{name}: RMS ours {rx:.1f}, MAME {ry:.1f} -> {db:+.2f} dB; 20 ms envelope correlation {cc:.3f}")
        seg = int(a.seg * 48000)
        segs = []
        for i in range(0, len(x) - seg + 1, seg):
            ya = np.sqrt((y[i:i + seg] ** 2).mean())
            if ya < 30:
                continue
            segs.append(20 * np.log10(np.sqrt((x[i:i + seg] ** 2).mean()) / ya))
        if segs:
            print(f"  {len(segs)} segments of {a.seg:.0f} s: {min(segs):+.2f} .. {max(segs):+.2f} dB, median {np.median(segs):+.2f}")
        ok = ok and abs(db) <= 1.0
    print("LEVEL " + ("OK (within 1 dB)" if ok else "OUT OF TOLERANCE"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
