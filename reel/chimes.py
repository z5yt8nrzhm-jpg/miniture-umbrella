"""Chimes-only track for flyer.html: a shop-door bell as each lady walks in, a soft chime as each pillow lands."""
import sys, wave
import numpy as np

SR, DUR = 48000, 13.0
N = int(SR * DUR)
mix = np.zeros((N, 2))
# (door bell time, pillow land time, pan) — from window.CUES in flyer.html (bell = mat start - 0.55)
CUES = [(2.661, 4.281, -0.6), (3.619, 5.239, 0.6), (6.625, 8.245, -0.2), (7.583, 9.203, 0.2)]
NOTES = [79, 83, 86, 91]  # G5 B5 D6 G6, climbing as the room fills


def hz(m):
    return 440 * 2 ** ((m - 69) / 12)


def bell(f, dur=2.0, decay=2.8):
    t = np.arange(int(dur * SR)) / SR
    s = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t * 5)
         + 0.15 * np.sin(2 * np.pi * f * 5.4 * t) * np.exp(-t * 9))
    return s * np.exp(-t * decay) * np.minimum(1, t / 0.002)


def add(sig, t, gain, pan):
    i = int(t * SR)
    sig = sig[: N - i] * gain
    mix[i:i + len(sig), 0] += sig * np.sqrt(0.5 * (1 - pan))
    mix[i:i + len(sig), 1] += sig * np.sqrt(0.5 * (1 + pan))


for k, (door, pillow, pan) in enumerate(CUES):
    add(bell(hz(96), 0.5, 9), door, 0.10, pan)           # tiny shop bell: two quick tings
    add(bell(hz(100), 0.5, 9), door + 0.09, 0.07, pan)
    add(bell(hz(NOTES[k])), pillow, 0.32, pan * 0.5)
    add(bell(hz(NOTES[k] + 12), 1.2, 4), pillow + 0.012, 0.06, pan * 0.5)

mix *= np.minimum(1, (DUR - np.arange(N) / SR) / 0.3)[:, None]
mix *= 0.7 / np.max(np.abs(mix))
with wave.open(sys.argv[1] if len(sys.argv) > 1 else "chimes.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())
