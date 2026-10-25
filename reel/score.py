"""Synthesize the reel's soundtrack: warm plucked-guitar bed + foley cues synced to reel.html."""
import sys, wave
import numpy as np
from scipy.signal import butter, sosfilt

SR, DUR = 48000, 21.0
N = int(SR * DUR)
rng = np.random.default_rng(7)
mix = np.zeros((N, 2))


def hz(m):
    return 440 * 2 ** ((m - 69) / 12)


def add(sig, t, gain=1.0, pan=0.0):
    i = int(t * SR)
    if i >= N:
        return
    sig = sig[: N - i] * gain
    mix[i:i + len(sig), 0] += sig * np.sqrt(0.5 * (1 - pan))
    mix[i:i + len(sig), 1] += sig * np.sqrt(0.5 * (1 + pan))


def filt(x, kind, f, order=2):
    return sosfilt(butter(order, f, btype=kind, fs=SR, output="sos"), x)


def pluck(freq, dur=1.8, bright=0.5):
    """Karplus-Strong string, vectorised one period at a time."""
    p = int(SR / freq)
    n = int(dur * SR)
    buf = filt(rng.uniform(-1, 1, p), "low", 1500 + 5000 * bright)
    out = np.empty(n)
    i = 0
    while i < n:
        k = min(p, n - i)
        out[i:i + k] = buf[:k]
        buf = 0.996 * 0.5 * (buf + np.roll(buf, -1))
        i += k
    env = np.minimum(1, np.arange(n) / (0.003 * SR))
    return out * env


def pad(freqs, dur):
    t = np.arange(int(dur * SR)) / SR
    s = sum(np.sin(2 * np.pi * f * t + i) + 0.5 * np.sin(2 * np.pi * f * 1.003 * t) for i, f in enumerate(freqs))
    env = np.minimum(1, t / 0.6) * np.minimum(1, (dur - t) / 0.8)
    return filt(s * env / len(freqs), "low", 1800)


def bell(freq, dur=1.6):
    t = np.arange(int(dur * SR)) / SR
    s = (np.sin(2 * np.pi * freq * t) + 0.4 * np.sin(2 * np.pi * freq * 2.76 * t) * np.exp(-t * 6)
         + 0.2 * np.sin(2 * np.pi * freq * 5.4 * t) * np.exp(-t * 10))
    return s * np.exp(-t * 3.2) * np.minimum(1, t / 0.002)


def noise_burst(dur, lo, hi, attack=0.005, decay=8.0):
    t = np.arange(int(dur * SR)) / SR
    x = filt(filt(rng.normal(0, 1, len(t)), "high", lo), "low", hi)
    return x * np.minimum(1, t / attack) * np.exp(-t * decay)


# ---- music: 96 bpm, Cmaj7 - Am7 - Fmaj7 - Gsus/G ----
BEAT = 60 / 96
BAR = 4 * BEAT
CHORDS = [[48, 55, 59, 64, 67], [45, 52, 55, 60, 64], [41, 48, 52, 57, 60], [43, 50, 55, 60, 62]]
ARP = [1, 2, 3, 4, 3, 2, 3, 4]
n_bars = int(np.ceil(DUR / BAR))
for b in range(n_bars):
    ch = CHORDS[b % 4]
    t0 = b * BAR
    if t0 > 19.6:
        break
    add(pad([hz(m + 12) for m in ch[1:4]], BAR + 0.6), t0, 0.07)
    add(pluck(hz(ch[0]), 2.4, 0.2), t0, 0.32, -0.1)                         # bass on 1
    add(pluck(hz(ch[0]), 1.4, 0.2), t0 + 2 * BEAT + BEAT / 2, 0.18, -0.1)   # and the "and" of 3
    for k, idx in enumerate(ARP):
        tt = t0 + k * BEAT / 2
        if tt < 0.45 or tt > 19.9:
            continue
        add(pluck(hz(ch[idx] + 12), 1.6, 0.55), tt, 0.16 if k % 2 == 0 else 0.11, 0.25 * (-1) ** k)
    # soft finger snaps on 2 & 4 once the girls arrive, shaker on off-8ths
    if t0 >= BAR:
        for k in (1, 3):
            add(noise_burst(0.12, 1800, 7000, 0.001, 38), t0 + k * BEAT, 0.22, 0.15)
    for k in range(8):
        tt = t0 + k * BEAT / 2 + BEAT / 4
        if 1.0 < tt < 19.8:
            add(noise_burst(0.07, 5000, 12000, 0.004, 55), tt, 0.05, 0.4 * (-1) ** k)
# final ring: Cmaj9 strum
for k, m in enumerate([48, 55, 59, 62, 64, 67, 71]):
    add(pluck(hz(m + 12 * (k > 2)), 3.0, 0.5), 19.6 + k * 0.025, 0.14, -0.3 + 0.1 * k)
add(bell(hz(84)), 19.62, 0.05)

# ---- foley synced to the animation ----
PENTA = [79, 81, 84, 86, 88, 91]
for i in range(19):                                   # string lights popping on
    if i % 2 == 0:
        add(bell(hz(PENTA[(i // 2) % 6] + 12), 0.8), 0.4 + i * 0.07, 0.025, -0.8 + i * 0.09)
for t_open, pan in ((2.3, -0.2), (2.75, 0.5)):        # can cracks + fizz
    add(noise_burst(0.02, 900, 9000, 0.0005, 300), t_open, 0.5, pan)
    hiss = noise_burst(1.3, 4000, 14000, 0.01, 2.6)
    crackle = (rng.random(len(hiss)) > 0.9975) * rng.uniform(0.3, 1, len(hiss))
    add(hiss + filt(crackle, "high", 3000) * np.exp(-np.arange(len(hiss)) / SR * 2.2), t_open + 0.01, 0.16, pan)
for t_c, g in ((4.02, 0.22), (4.11, 0.12)):           # cups clink
    t = np.arange(int(0.8 * SR)) / SR
    s = sum(a * np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, a, d in ((2380, 1, 7), (3460, 0.6, 9), (5120, 0.35, 13)))
    add(s * np.minimum(1, t / 0.0008), t_c, g, 0.0)
for i in range(4):                                    # mats unroll + cushions pop
    sw = noise_burst(0.7, 300, 2500, 0.25, 3.5)
    add(sw, 7.0 + i * 0.12, 0.05, -0.6 + 0.4 * i)
    t = np.arange(int(0.18 * SR)) / SR
    add(np.sin(2 * np.pi * (180 - 300 * t) * t) * np.exp(-t * 28), 8.0 + i * 0.1 + 0.08, 0.22, -0.6 + 0.4 * i)
for k, (tt, m) in enumerate(((12.15, 76), (12.9, 79), (13.65, 81), (14.4, 84))):   # pillar chimes
    add(bell(hz(m)), tt, 0.07, -0.3 + 0.2 * k)
for k in range(5):
    add(bell(hz(91 + k * 2), 0.6), 14.5 + k * 0.1, 0.02, 0.5 - 0.25 * k)
add(noise_burst(0.5, 400, 3000, 0.15, 6), 15.3, 0.05)          # details card whoosh
for j in range(4):
    add(bell(hz(88), 0.3), 16.2 + j * 0.2, 0.015)
add(bell(hz(79)), 17.2, 0.06); add(bell(hz(86)), 17.28, 0.04)   # CTA

# ---- master ----
mix[:, 0] = filt(mix[:, 0], "high", 35)
mix[:, 1] = filt(mix[:, 1], "high", 35)
tail = np.minimum(1, (DUR - np.arange(N) / SR) / 0.6)[:, None]
head = np.minimum(1, np.arange(N) / SR / 0.05)[:, None]
mix *= tail * head
mix = np.tanh(mix * 1.6) / np.tanh(1.6)
mix *= 0.89 / np.max(np.abs(mix))
out = sys.argv[1] if len(sys.argv) > 1 else "score.wav"
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((mix * 32767).astype("<i2").tobytes())
print("wrote", out)
