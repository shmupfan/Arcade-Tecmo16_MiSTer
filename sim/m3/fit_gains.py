#!/usr/bin/env python3
"""Fit the YM2151 and M6295 mix gains against MAME's WAV.

    m3/fit_gains.py SEP.raw MAME.wav [--lead MS] [--win MS]

SEP.raw: tb_sys +wavsep (YM left, YM right, M6295 14-bit, int16 triples at
48 kHz, same instants as +wav). The two chips are independent sources, so in
each window the MAME channel's power is P = gy^2 * Py + go^2 * Po (cross
terms average out over a window). A least-squares fit over all windows with
sound gives the gains in core units: MAME_out = gy * ym + go * oki. jt51 and
ymfm are not sample-identical and MAME resamples the M6295, so this fits
powers, not waveforms. Reports the fit, the residual, and the gains as the
t16_snd YM_GAIN / OKI_GAIN parameters (x/256).
"""
import argparse, sys, wave
import numpy as np

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sep"); ap.add_argument("mame")
    ap.add_argument("--lead", type=float, default=0.683012)
    ap.add_argument("--win", type=float, default=20.0)
    ap.add_argument("--band", type=float, default=3500.0,
                    help="low-pass both sides at this frequency (Hz) before fitting; 0 = off. "
                         "The M6295 runs at 7,576 Hz: the core's raw output keeps the sample-and-hold "
                         "images above 3.8 kHz that MAME's resampler removes, so full-band power is "
                         "not comparable")
    a = ap.parse_args()
    s = np.fromfile(a.sep, dtype="<i2").astype(np.float64).reshape(-1, 3)
    s = s[int(round(a.lead * 48)):]
    w = wave.open(a.mame)
    m = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64).reshape(-1, w.getnchannels())
    n = min(len(s), len(m)); s, m = s[:n], m[:n]
    if a.band > 0:
        def lp(x):
            X = np.fft.rfft(x, axis=0)
            f = np.fft.rfftfreq(len(x), 1 / 48000)
            X[f > a.band] = 0
            return np.fft.irfft(X, n=len(x), axis=0)
        s, m = lp(s), lp(m)
    win = int(a.win * 48)
    k = n // win
    def pw(x): return (x[:k * win].reshape(k, win) ** 2).mean(axis=1)
    py, po, pm = pw(s[:, 0]), pw(s[:, 2]), pw(m[:, 0])
    sel = (pm > 100) & np.isfinite(pm)
    A = np.stack([py[sel], po[sel]], axis=1)
    coef, res, *_ = np.linalg.lstsq(A, pm[sel], rcond=None)
    gy, go = np.sqrt(np.clip(coef, 0, None))
    pred = A @ coef
    r2 = 1 - ((pm[sel] - pred) ** 2).sum() / ((pm[sel] - pm[sel].mean()) ** 2).sum()
    print(f"{sel.sum()} windows of {a.win:.0f} ms with sound; R^2 {r2:.3f}")
    print(f"MAME = {gy:.4f} x jt51 xleft + {go:.4f} x jt6295 sound")
    print(f"as t16_snd parameters: YM_GAIN {gy * 256:.1f}/256, OKI_GAIN {go * 256:.1f}/256")
    # windows where one source dominates, for a check of each gain alone
    for name, p, q, g in (("YM only", py, po, gy), ("M6295 only", po, py, go)):
        only = sel & (p > 50 * q) & (p > 0)
        if only.sum() > 20:
            ratio = np.sqrt(np.median(pm[only] / p[only]))
            print(f"  {name}: {only.sum()} windows, median gain {ratio:.4f} (fit {g:.4f})")
    return 0

if __name__ == "__main__":
    sys.exit(main())
