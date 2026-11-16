#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the beat-grid conformance vectors under conformance/beatgrid/.

Each vector is a synthetic score (synthesis events with exact beat and downbeat annotations)
and the grid this script's model of conformance/beatgrid/README.md computes for it.

The renderer uses only addition, subtraction, multiplication, division, floor and comparisons
on IEEE doubles, so crates/oscillux-core/tests/beatgrid_vectors.rs reproduces the 16-bit
samples exactly and checks them against the FNV-1a digest recorded here. The audio is rendered
at test time and not committed.

The model is an independent standard-library Python implementation written from the README.
It shares no code or intermediate values with the Rust module and computes differently where
the specification allows: one half-length complex FFT per frame over its even and odd samples
(Rust transforms two real frames per complex FFT), correctly rounded math.fsum sums (Rust adds
in order), direct window sums for the local means (Rust uses prefix sums) and a linear scan for
the clock's beat (Rust searches by bisection). Expected grids come from this model only; Rust output
is compared with them within the published tolerances and is never copied in.

Usage: python3 tools/beatgrid-vectors.py
       python3 tools/beatgrid-vectors.py --check   (exit 1 if a generated file differs)

--check writes into a temporary directory and compares it with conformance/beatgrid/ file by
file, so a missing, extra or changed file fails.
"""

import cmath
import filecmp
import itertools
import math
import operator
import os
import sys
import tempfile
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIR = os.path.join(ROOT, "conformance", "beatgrid")

GAIN = 0.5
NOISE_TABLE_SIZE = 1 << 16
NOISE_SEED = 20261023
LEAD_IN_SECONDS = 0.5
TAIL_SECONDS = 1.0


# --- Synthesis ---------------------------------------------------------------------------------

def noise_table():
    """65536 uniform values in [-0.5, 0.5) from a 64-bit LCG."""
    state, table = NOISE_SEED, []
    for _ in range(NOISE_TABLE_SIZE):
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        table.append((state >> 11) / 2.0 ** 53 - 0.5)
    return table


NOISE = noise_table()


def envelope(length, attack, release, amp, decay):
    """((amp * a_i) * r_i) * d_i: linear attack over `attack` samples, linear release over the
    last `release` samples, and d_0 = 1, d_(i+1) = d_i * decay."""
    decays = itertools.accumulate(itertools.repeat(decay, length - 1), operator.mul, initial=1.0)
    out = []
    for i, d in enumerate(decays):
        a = i / attack if i < attack else 1.0
        r = (length - i) / release if length - i < release else 1.0
        out.append(((amp * a) * r) * d)
    return out


def sine_shape(p):
    """Parabolic sine of the phase fraction p in [0, 1), refined: y = 0.225 (y |y| - y) + y."""
    if p < 0.5:
        y = 16.0 * p * (0.5 - p)
    else:
        q = p - 0.5
        y = -16.0 * q * (0.5 - q)
    return 0.225 * (y * abs(y) - y) + y


def tone(length, rate, f_start, f_end, glide):
    """Frequency f_end + (f_start - f_end) g_i with g_0 = 1, g_(i+1) = g_i * glide; phase
    P_0 = 0, P_(i+1) = P_i + f_i * (1 / rate)."""
    glides = itertools.accumulate(itertools.repeat(glide, length - 1), operator.mul, initial=1.0)
    span, step = f_start - f_end, 1.0 / rate
    increments = [(f_end + span * g) * step for g in glides]
    phases = itertools.accumulate(increments[:-1], operator.add, initial=0.0)
    return [sine_shape(p - math.floor(p)) for p in phases]


def noise(length, seed, highpass):
    """Table noise from index seed: plain, first difference or second difference."""
    t, mask = NOISE, NOISE_TABLE_SIZE - 1
    if highpass == 0:
        return [t[(seed + i) & mask] for i in range(length)]
    if highpass == 1:
        return [t[(seed + i) & mask] - t[(seed + i - 1) & mask] for i in range(length)]
    return [(t[(seed + i) & mask] - t[(seed + i - 1) & mask])
            - (t[(seed + i - 1) & mask] - t[(seed + i - 2) & mask]) for i in range(length)]


def quantise(value):
    """Clamp to [-1, 1] and round value * 32767 half away from zero."""
    x = max(-1.0, min(1.0, value)) * 32767
    return int(math.copysign(math.floor(abs(x) + 0.5), x))


def render(score):
    """Interleaved 16-bit samples: events summed in file order into one signal, then channel c
    is quantise((gain * pan_c) * x)."""
    buf = [0.0] * score["samples"]
    for event in score["events"]:
        kind, start, length, attack, release, amp, decay = event[:7]
        env = envelope(length, attack, release, amp, decay)
        if kind == "tone":
            shape = tone(length, score["rate"], *event[7:10])
        else:
            shape = noise(length, *event[7:9])
        for i, (e, s) in enumerate(zip(env, shape)):
            buf[start + i] += e * s
    gains = [GAIN * pan for pan in score["pan"]]
    return [quantise(g * x) for x in buf for g in gains]


def fnv1a(data):
    h = 0xcbf29ce484222325
    for byte in data:
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def pcm_fnv1a(pcm):
    """FNV-1a over the little-endian bytes of the 16-bit samples."""
    return fnv1a(b"".join(int.to_bytes(s & 0xFFFF, 2, "little") for s in pcm))


# --- Instruments and arrangements --------------------------------------------------------------

class Score:
    def __init__(self, name, description, rate, hint=0, pan=(1.0,)):
        self.name, self.description, self.rate = name, description, rate
        self.hint, self.pan = hint, list(pan)
        self.events, self.beats = [], []
        self.seed = 3

    def samples(self, seconds):
        return int(math.floor(seconds * self.rate + 0.5))

    def per_sample(self, tau_seconds):
        """Per-sample factor of an exponential with time constant tau."""
        return math.exp(-1.0 / (tau_seconds * self.rate))

    def add(self, *event):
        self.events.append(event)

    def next_seed(self, length):
        seed = self.seed
        self.seed = (self.seed + length + 7919) & (NOISE_TABLE_SIZE - 1)
        return seed

    def kick(self, at, level=1.0):
        s = self.samples
        self.add("tone", at, s(0.3), s(0.0005), s(0.01), 0.85 * level, self.per_sample(0.07),
                 160.0, 48.0, self.per_sample(0.025))

    def snare(self, at, level=1.0):
        s, length = self.samples, self.samples(0.2)
        self.add("tone", at, s(0.18), s(0.0005), s(0.01), 0.3 * level, self.per_sample(0.04),
                 220.0, 180.0, self.per_sample(0.01))
        self.add("noise", at, length, s(0.0005), s(0.01), 0.6 * level, self.per_sample(0.06),
                 self.next_seed(length), 1)

    def hat(self, at, level=1.0):
        s, length = self.samples, self.samples(0.05)
        self.add("noise", at, length, s(0.00025), s(0.005), 0.3 * level, self.per_sample(0.012),
                 self.next_seed(length), 2)

    def click(self, at, level=1.0):
        """A 20 ms second-difference noise burst with a one-sample attack."""
        length = self.samples(0.02)
        self.add("noise", at, length, 1, self.samples(0.002), 0.8 * level,
                 self.per_sample(0.004), self.next_seed(length), 2)

    def bass(self, at, seconds, hz, level=1.0):
        s = self.samples
        self.add("tone", at, s(seconds), s(0.005), s(0.03), 0.35 * level, self.per_sample(0.5),
                 hz, hz, 1.0)

    def chord(self, at, seconds, freqs, level=1.0):
        s = self.samples
        for hz in freqs:
            self.add("tone", at, s(seconds), s(0.005), s(0.05), 0.07 * level,
                     self.per_sample(1.5), hz, hz, 1.0)

    def beat(self, at, beat_in_bar):
        self.beats.append((at, beat_in_bar))

    def finish(self):
        last = max(start + length for _, start, length, *_ in self.events)
        total = max(last, self.beats[-1][0]) + self.samples(TAIL_SECONDS)
        return {"name": self.name, "description": self.description, "rate": self.rate,
                "pan": self.pan, "hint": self.hint, "samples": total, "events": self.events,
                "beats": self.beats}


# Am, F, C, G: one chord per bar, cycling, with its root two octaves down.
CHORDS = ((220.0, 261.63, 329.63), (174.61, 220.0, 261.63),
          (261.63, 329.63, 392.0), (196.0, 246.94, 293.66))
ROOTS = (55.0, 43.65, 65.41, 49.0)


def beat_times(start, seconds, bpm_at):
    """Beat times from `start` while t < start + seconds, each interval 60 / bpm_at(t)."""
    t, out = start, []
    while t < start + seconds:
        out.append(t)
        t += 60.0 / bpm_at(t)
    return out


def groove(score, times, meter=4):
    """Kick on 1 and 3, snare on 2 and 4, eighth hats, the bar's root on 1 and its chord held
    for the bar; the bar's last beat is cut off when the times run out."""
    for k, t in enumerate(times):
        period = (times[k + 1] - t) if k + 1 < len(times) else (t - times[k - 1])
        at, slot, bar = score.samples(t), k % meter, k // meter
        score.beat(at, slot)
        if slot in (0, 2):
            score.kick(at, 1.0 if slot == 0 else 0.8)
        else:
            score.snare(at)
        score.hat(at, 0.8)
        score.hat(score.samples(t + period / 2), 0.5)
        if slot == 0:
            bar_seconds = period * meter
            score.bass(at, bar_seconds * 0.9, ROOTS[bar % 4])
            score.chord(at, bar_seconds * 0.95, CHORDS[bar % 4])


def clicks():
    s = Score("clicks-120-44k1", "120 BPM clicks, 4/4: a 20 ms noise click on every beat, louder "
              "on beat 1, which also has a kick; 40 beats; meter hint 4", 44100, hint=4)
    for k, t in enumerate(beat_times(LEAD_IN_SECONDS, 20.0, lambda t: 120.0)):
        at = s.samples(t)
        s.beat(at, k % 4)
        s.click(at, 1.0 if k % 4 == 0 else 0.6)
        if k % 4 == 0:
            s.kick(at, 0.7)
    return s.finish()


def waltz():
    s = Score("waltz-90-48k", "90 BPM waltz, 3/4, stereo (right channel at half level): root "
              "and kick on 1, the bar's chord on 2 and 3, a hat on every beat; auto meter",
              48000, pan=(1.0, 0.5))
    times = beat_times(LEAD_IN_SECONDS, 16.0, lambda t: 90.0)
    for k, t in enumerate(times):
        at, slot, bar = s.samples(t), k % 3, k // 3
        s.beat(at, slot)
        s.hat(at, 0.6)
        if slot == 0:
            s.kick(at, 0.8)
            s.bass(at, 0.6, ROOTS[bar % 4])
        else:
            s.chord(at, 0.35, CHORDS[bar % 4], 1.6)
    return s.finish()


def ramp():
    def bpm(t):
        x = min(1.0, max(0.0, (t - 3.5) / 22.0))
        return 90.0 + 60.0 * x
    s = Score("ramp-90-150-22k05", "groove ramping linearly from 90 to 150 BPM: 3 s at 90, a "
              "22 s ramp, then 150 to the end; 4/4; meter hint 4", 22050, hint=4)
    groove(s, beat_times(LEAD_IN_SECONDS, 29.0, bpm))
    return s.finish()


def step():
    s = Score("step-100-140-22k05", "groove at 100 BPM for 14 s, then 140 BPM; 4/4; auto meter",
              22050)
    groove(s, beat_times(LEAD_IN_SECONDS, 28.0, lambda t: 100.0 if t < 14.5 else 140.0))
    return s.finish()


def fast():
    s = Score("fast-200-8k", "200 BPM four on the floor at 8 kHz: kick and hat on every beat, "
              "snare on 2 and 4, the bar's root on 1; meter hint 4", 8000, hint=4)
    times = beat_times(LEAD_IN_SECONDS, 14.0, lambda t: 200.0)
    for k, t in enumerate(times):
        at, slot, bar = s.samples(t), k % 4, k // 4
        s.beat(at, slot)
        s.kick(at, 1.0 if slot == 0 else 0.7)
        s.hat(at, 0.6)
        if slot in (1, 3):
            s.snare(at, 0.7)
        if slot == 0:
            s.bass(at, 1.0, ROOTS[bar % 4])
    return s.finish()


def groove_110():
    s = Score("groove-110-44k1", "110 BPM groove, 4/4, auto meter", 44100)
    groove(s, beat_times(LEAD_IN_SECONDS, 18.0, lambda t: 110.0))
    return s.finish()


SCORES = (clicks, waltz, ramp, step, fast, groove_110)


# --- Model of conformance/beatgrid/README.md ---------------------------------------------------

# Analysis defaults (README "Configuration" and "Tuning").
MIN_BPM = 40.0
MAX_BPM = 240.0
NORM_HALF_S = 1.0
LOW_WEIGHT = 1.0
PRIOR_BPM = 140.0
PRIOR_OCTAVES = 2.0
PATH_HALF_S = 4.0
PATH_SPAN = 2.0
PATH_CHANGE = 4.0
PATH_PULL = 1.0
TIGHTNESS = 100.0
DOWN_HARMONIC = 1.0
DOWN_LOW = 1.0
DOWN_JUMP = 4.0
OFFSET_S = 0.009

BAND_MIN_HZ = 27.5
BAND_MAX_HZ = 16000.0
GAMMA = 100.0
LOW_MAX_HZ = 150.0
CHROMA_MIN_HZ = 60.0
CHROMA_MAX_HZ = 4000.0
LAG_STEP = 0.25
BIN_STEP = 0.5


def round_half_away(x):
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def window_len(rate):
    least = max(int(rate * 0.04), 4)
    n = 1
    while n < least:
        n *= 2
    return n


def hop_len(rate):
    return max(int(rate / 100.0 + 0.5), 1)


_FFT_CACHE = {}


def _fft_tables(m):
    """Bit-reversal order and per-stage twiddles of an m-point complex FFT."""
    if m not in _FFT_CACHE:
        bits = m.bit_length() - 1
        order = [int(format(i, "0%db" % bits)[::-1], 2) if bits else 0 for i in range(m)]
        stages = []
        size = 2
        while size <= m:
            stages.append([cmath.exp(-2j * math.pi * k / size) for k in range(size // 2)])
            size *= 2
        _FFT_CACHE[m] = (order, stages)
    return _FFT_CACHE[m]


def fft(values):
    """Iterative radix-2 decimation-in-time FFT of a power-of-two list of complex values."""
    m = len(values)
    order, stages = _fft_tables(m)
    a = [values[i] for i in order]
    size = 2
    for twiddles in stages:
        half = size // 2
        for base in range(0, m, size):
            for k in range(half):
                i = base + k
                t = twiddles[k] * a[i + half]
                a[i + half] = a[i] - t
                a[i] = a[i] + t
        size *= 2
    return a


def real_magnitudes(x):
    """|X[k]| for k = 0 .. n/2 of the DFT of the real list x, from one n/2-point complex FFT of
    the even and odd samples."""
    n = len(x)
    h = n // 2
    z = fft([complex(x[2 * k], x[2 * k + 1]) for k in range(h)])
    out = []
    for k in range(h + 1):
        zk = z[k % h]
        zc = z[(h - k) % h].conjugate()
        even = 0.5 * (zk + zc)
        odd = -0.5j * (zk - zc)
        out.append(abs(even + cmath.exp(-2j * math.pi * k / n) * odd))
    return out


def model_features(mono, rate):
    """README "Onset features": broadband and low-band flux and the pitch-class profiles."""
    n = window_len(rate)
    hop = hop_len(rate)
    frames = len(mono) // hop + 1
    window = [0.5 - 0.5 * math.cos(2.0 * math.pi * j / n) for j in range(n)]
    scale = 4.0 / n
    top = min(BAND_MAX_HZ, rate / 2.0)

    def band_of(f):
        x = 12.0 * math.log2(f / BAND_MIN_HZ) + 0.5
        if abs(x - round(x)) < 1e-9:
            raise ValueError("bin at %r Hz is on a band boundary" % f)
        return int(x)

    bands = band_of(top) + 1
    members = [[] for _ in range(bands)]
    for k in range(n // 2 + 1):
        f = k * rate / n
        if BAND_MIN_HZ <= f <= top:
            members[band_of(f)].append(k)
    used = [bool(m) for m in members]
    low_bands = min(band_of(LOW_MAX_HZ), bands)
    chroma_lo = band_of(CHROMA_MIN_HZ)
    chroma_hi = min(band_of(CHROMA_MAX_HZ), bands - 1)
    # the previous-frame reference of band b covers its used neighbours
    neighbours = [[c for c in (b - 1, b, b + 1) if 0 <= c < bands and used[c]] for b in range(bands)]
    flux, low, chroma = [], [], []
    prev = None
    for i in range(frames):
        start = i * hop - n // 2
        x = [mono[start + j] * window[j] if 0 <= start + j < len(mono) else 0.0
             for j in range(n)]
        mags = real_magnitudes(x)
        cur = [math.log(1.0 + GAMMA * scale * math.fsum(mags[k] for k in members[b]))
               if used[b] else 0.0 for b in range(bands)]
        rises = [0.0] * bands
        if prev is not None:
            for b in range(bands):
                if used[b]:
                    rises[b] = max(0.0, cur[b] - max(prev[c] for c in neighbours[b]))
        flux.append(math.fsum(rises))
        low.append(math.fsum(rises[:low_bands]))
        profile = [0.0] * 12
        for b in range(chroma_lo, chroma_hi + 1):
            if used[b]:
                profile[b % 12] += cur[b]
        chroma.append(profile)
        prev = cur
    return {"rate": rate, "hop": hop, "flux": flux, "low": low, "chroma": chroma}


def model_normalise(x, half):
    """x minus its mean over the +/-half frames in range, scaled to unit RMS."""
    n = len(x)
    out = []
    for i in range(n):
        lo, hi = max(0, i - half), min(n, i + half + 1)
        out.append(x[i] - math.fsum(x[lo:hi]) / (hi - lo))
    sd = math.sqrt(math.fsum(v * v for v in out) / max(n, 1))
    return [v / sd for v in out] if sd > 0.0 else out


def model_autocorrelation(x, max_lag):
    n = len(x)
    r = [math.fsum(map(operator.mul, x[:n - tau], x[tau:])) if tau < n else 0.0
         for tau in range(max_lag + 1)]
    return [v / r[0] for v in r] if r[0] > 0.0 else r


def model_at(r, lag):
    if lag < 0.0:
        return 0.0
    i = int(math.floor(lag))
    if i + 1 >= len(r):
        return 0.0
    f = lag - i
    return r[i] * (1.0 - f) + r[i + 1] * f


def model_salience(r, lag):
    return math.fsum(model_at(r, k * lag) for k in (1, 2, 3, 4))


def model_global_period(r, lo, hi, centre, octaves):
    steps = int(math.floor((hi - lo) / LAG_STEP))

    def score(k):
        lag = lo + k * LAG_STEP
        z = math.log2(lag / centre) / octaves
        return model_salience(r, lag) * math.exp(-0.5 * z * z)

    scores = [score(k) for k in range(steps + 1)]
    best = scores.index(max(scores))
    lag = lo + best * LAG_STEP
    if 0 < best < steps:
        a, b, c = scores[best - 1], scores[best], scores[best + 1]
        den = a - 2.0 * b + c
        if den < 0.0:
            lag += 0.5 * (a - c) / den * LAG_STEP
    return lag


def model_tempo_path(x, glob, lo, hi, half, hop):
    n = len(x)
    lmin, lmax = max(lo, glob / PATH_SPAN), min(hi, glob * PATH_SPAN)
    bins = max(int(math.floor((lmax - lmin) / BIN_STEP)) + 1, 1)
    lags = [lmin + b * BIN_STEP for b in range(bins)]
    max_lag = int(math.ceil(4.0 * lmax)) + 2
    centres = max(-(-n // hop), 1)
    weights = [0.5 - 0.5 * math.cos(2.0 * math.pi * (j + 1) / (2 * half + 2))
               for j in range(2 * half + 1)]
    pull = []
    for l in lags:
        d = math.log2(l / glob)
        pull.append(PATH_PULL * d * d)
    move = [[PATH_CHANGE * math.log2(l / a) ** 2 for a in lags] for l in lags]
    score, back = None, []
    for c in range(centres):
        centre = c * hop
        start, end = max(centre - half, 0), min(centre + half + 1, n)
        wx = [weights[i - centre + half] * x[i] for i in range(start, end)]
        span = end - start
        r = [math.fsum(map(operator.mul, wx[:span - tau], x[start + tau:end]))
             if tau < span else 0.0 for tau in range(max_lag + 1)]
        if r[0] > 0.0:
            r = [v / r[0] for v in r]
        local = [0.5 * model_salience(r, l) - p for l, p in zip(lags, pull)]
        if score is None:
            score = local
            back.append([0] * bins)
            continue
        nxt, arg = [], []
        for b in range(bins):
            options = [s - m for s, m in zip(score, move[b])]
            best = max(options)
            arg.append(options.index(best))
            nxt.append(best + local[b])
        score = nxt
        back.append(arg)
    b = score.index(max(score))
    path = [0.0] * centres
    for c in range(centres - 1, -1, -1):
        path[c] = lags[b]
        b = back[c][b]
    out = []
    for i in range(n):
        c = i // hop
        f = (i - c * hop) / hop
        out.append(path[c] * (1.0 - f) + path[c + 1] * f if c + 1 < centres else path[-1])
    return out


def model_track(env, period):
    """README "Beats": the beat frames maximising the summed envelope less the interval cost."""
    n = len(env)
    score, back = [0.0] * n, [None] * n
    for t in range(n):
        tau = period[t]
        lo, hi = t - 2.0 * tau, t - 0.5 * tau
        best, arg = 0.0, None
        if hi >= 0.0:
            for p in range(max(int(math.ceil(lo)), 0), int(math.floor(hi)) + 1):
                d = math.log((t - p) / tau)
                s = score[p] - TIGHTNESS * d * d
                if s > best:
                    best, arg = s, p
        score[t] = env[t] + best
        back[t] = arg
    t = score.index(max(score))
    beats = [t]
    while back[t] is not None:
        t = back[t]
        beats.append(t)
    return beats[::-1]


def model_refine(env, b):
    n = len(env)
    m = min(b, n - 1)
    for i in range(max(b - 2, 0), min(b + 2, n - 1) + 1):
        if env[i] > env[m]:
            m = i
    if m == 0 or m + 1 >= n:
        return float(m)
    a, c, d = env[m - 1], env[m], env[m + 1]
    den = a - 2.0 * c + d
    # interpolate only at a local maximum of its neighbours
    return m + 0.5 * (a - d) / den if a <= c and d <= c and den < 0.0 else float(m)


def model_standardise(v):
    n = max(len(v), 1)
    mean = math.fsum(v) / n
    sd = math.sqrt(math.fsum((x - mean) ** 2 for x in v) / n)
    return [(x - mean) / sd if sd > 0.0 else 0.0 for x in v]


def model_cue(beats, chroma, low):
    n, frames = len(beats), len(chroma)
    profiles = []
    for i in range(n):
        start = min(beats[i], frames)
        end = max(min(beats[i + 1] if i + 1 < n else frames, frames), start)
        m = [math.fsum(c[k] for c in chroma[start:end]) for k in range(12)]
        norm = math.sqrt(math.fsum(v * v for v in m))
        profiles.append([v / norm for v in m] if norm > 0.0 else m)
    harmonic = [0.0] + [1.0 - math.fsum(a * b for a, b in zip(profiles[i - 1], profiles[i]))
                        for i in range(1, n)]
    bass = [max([0.0] + low[max(b - 2, 0):min(b + 3, len(low))]) for b in beats]
    harmonic, bass = model_standardise(harmonic), model_standardise(bass)
    return [DOWN_HARMONIC * h + DOWN_LOW * l for h, l in zip(harmonic, bass)]


def model_decode(cue, m):
    """Bar positions under meter m and their contrast (README "Bars")."""
    n = len(cue)
    score, back = None, []
    for i, c in enumerate(cue):
        emit = [c] + [0.0] * (m - 1)
        if score is None:
            score = emit
            back.append([0] * m)
            continue
        nxt, arg = [], []
        for pos in range(m):
            follow = (pos - 1) % m
            best, a = score[follow], follow
            for q in range(m):
                if q != follow and score[q] - DOWN_JUMP > best:
                    best, a = score[q] - DOWN_JUMP, q
            nxt.append(best + emit[pos])
            arg.append(a)
        score = nxt
        back.append(arg)
    pos = score.index(max(score))
    out = [0] * n
    for i in range(n - 1, -1, -1):
        out[i] = pos
        pos = back[i][pos]
    down = [c for c, p in zip(cue, out) if p == 0]
    other = [c for c, p in zip(cue, out) if p != 0]
    contrast = math.fsum(down) / max(len(down), 1) - math.fsum(other) / max(len(other), 1)
    return out, contrast


def model_grid(pcm, rate, channels, hint):
    """README "Grid": the beats and summary for interleaved 16-bit pcm."""
    mono = [math.fsum(s / 32768.0 for s in pcm[i:i + channels]) / channels
            for i in range(0, len(pcm), channels)]
    duration = len(mono) / rate
    empty = {"beats": [], "bar_count": 0, "beats_per_bar": 0, "tempo_bpm": 0.0,
             "confidence": 0.0, "duration_s": duration}
    feat = model_features(mono, rate)
    fps = rate / feat["hop"]
    lo, hi = 60.0 * fps / MAX_BPM, 60.0 * fps / MIN_BPM
    if len(feat["flux"]) < 4.0 * hi or lo < 2.0:
        return empty
    half = round_half_away(NORM_HALF_S * fps)
    broad = model_normalise(feat["flux"], half)
    low = model_normalise(feat["low"], half)
    r = model_autocorrelation(broad, int(math.ceil(4.0 * hi)) + 2)
    if r[0] == 0.0:
        return empty
    glob = model_global_period(r, lo, hi, 60.0 * fps / PRIOR_BPM, PRIOR_OCTAVES)
    path = model_tempo_path(broad, glob, lo, hi, round_half_away(PATH_HALF_S * fps),
                            max(round_half_away(fps / 2.0), 1))
    env = [b + LOW_WEIGHT * l for b, l in zip(broad, low)]
    frames = model_track(env, path)
    if len(frames) < 2:
        return empty
    times = [model_refine(env, b) / fps + OFFSET_S for b in frames]
    cue = model_cue(frames, feat["chroma"], low)
    if hint >= 2:
        meter, positions = hint, model_decode(cue, hint)[0]
    else:
        meter, positions, best = 0, None, None
        for m in (4, 3):
            p, c = model_decode(cue, m)
            if best is None or c > best:
                meter, positions, best = m, p, c
    beats, bar, bars = [], 0, 0
    n = len(times)
    for i in range(n):
        if positions[i] == 0:
            bars += 1
            if i > 0:
                bar += 1
        if i == 0:
            span = times[1] - times[0]
        elif i + 1 == n:
            span = times[i] - times[i - 1]
        else:
            span = 0.5 * (times[i + 1] - times[i - 1])
        beats.append((times[i], 60.0 / span if span > 0.0 else 0.0, positions[i], bar))
    return {"beats": beats, "bar_count": bars, "beats_per_bar": meter,
            "tempo_bpm": 60.0 * fps / glob,
            "confidence": min(1.0, max(0.0, model_at(r, glob))), "duration_s": duration}


def model_clock(grid, t):
    """README "Clock": (beat_phase, bar_phase, tempo_bpm, beat_index, beat_in_bar) at t."""
    b = grid["beats"]
    n = len(b)
    meter = max(grid["beats_per_bar"], 1)
    if n < 2:
        return (0.0, 0.0, 0.0, -1, 0)
    if t < b[0][0]:
        iv = b[1][0] - b[0][0]
        k = math.floor((t - b[0][0]) / iv)
        index, start, pos, tempo = k, b[0][0] + k * iv, (b[0][2] + k) % meter, b[0][1]
    elif t >= b[-1][0]:
        iv = b[-1][0] - b[-2][0]
        k = math.floor((t - b[-1][0]) / iv)
        index, start, pos, tempo = n - 1 + k, b[-1][0] + k * iv, (b[-1][2] + k) % meter, b[-1][1]
    else:
        index = max(i for i in range(n) if b[i][0] <= t)
        iv = b[index + 1][0] - b[index][0]
        start, pos, tempo = b[index][0], b[index][2], b[index][1]
    below_one = 1.0 - 2.0 ** -53
    phase = min(max((t - start) / iv, 0.0), below_one) if iv > 0.0 else 0.0
    return (phase, min((pos % meter + phase) / meter, below_one), tempo, index, pos)


def clock_times(grid):
    """Sample times: before the first beat, midway between every pair, after the last."""
    b = [beat[0] for beat in grid["beats"]]
    if len(b) < 2:
        return [0.0, 1.0]
    out = [b[0] - 1.6 * (b[1] - b[0]), b[0] - 0.4 * (b[1] - b[0])]
    out += [0.5 * (b[i] + b[i + 1]) for i in range(len(b) - 1)]
    out += [b[-1] + 0.3 * (b[-1] - b[-2]), b[-1] + 2.7 * (b[-1] - b[-2])]
    return out


def grid_text(score, grid):
    lines = [
        "# beatgrid-grid v1",
        "# Generated by tools/beatgrid-vectors.py from %s.score with the model of" % score["name"],
        "# conformance/beatgrid/README.md; tolerances are in the README.",
        "name " + score["name"],
        "config rate %d channels %d beats_per_bar %d"
        % (score["rate"], len(score["pan"]), score["hint"]),
        "info beat_count %d bar_count %d beats_per_bar %d" % (
            len(grid["beats"]), grid["bar_count"], grid["beats_per_bar"]),
        "tempo_bpm " + repr(grid["tempo_bpm"]),
        "confidence " + repr(grid["confidence"]),
        "duration_s " + repr(grid["duration_s"]),
        "# beat time_s tempo_bpm beat_in_bar bar_index",
    ]
    lines.extend("beat %r %r %d %d" % beat for beat in grid["beats"])
    lines.append("# clock media_time_s beat_phase bar_phase tempo_bpm beat_index beat_in_bar")
    for t in clock_times(grid):
        lines.append("clock %r %r %r %r %d %d" % ((t,) + model_clock(grid, t)))
    return "\n".join(lines) + "\n"


def score_text(score, digest):
    lines = [
        "# beatgrid-score v1",
        "# Generated by tools/beatgrid-vectors.py; conformance/beatgrid/README.md describes it.",
        "name " + score["name"],
        "description " + score["description"],
        "rate %d" % score["rate"],
        "pan " + " ".join(repr(p) for p in score["pan"]),
        "gain " + repr(GAIN),
        "samples %d" % score["samples"],
        "beats_per_bar_hint %d" % score["hint"],
        "pcm_fnv1a %016x" % digest,
        "# tone start length attack release amp decay f_start f_end glide",
        "# noise start length attack release amp decay seed highpass",
    ]
    for event in score["events"]:
        lines.append(" ".join([event[0]] + [repr(v) for v in event[1:]]))
    lines.append("# beat sample beat_in_bar")
    lines.extend("beat %d %d" % b for b in score["beats"])
    return "\n".join(lines) + "\n"


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for make in SCORES:
        started = time.time()
        score = make()
        pcm = render(score)
        with open(os.path.join(out_dir, score["name"] + ".score"), "w") as handle:
            handle.write(score_text(score, pcm_fnv1a(pcm)))
        rendered = time.time()
        grid = model_grid(pcm, score["rate"], len(score["pan"]), score["hint"])
        with open(os.path.join(out_dir, score["name"] + ".grid"), "w") as handle:
            handle.write(grid_text(score, grid))
        print("%-22s %5.1f s at %5d Hz, %3d beats, %3d found, meter %d; rendered in %.1f s, "
              "analysed in %.1f s"
              % (score["name"], score["samples"] / score["rate"], score["rate"],
                 len(score["beats"]), len(grid["beats"]), grid["beats_per_bar"],
                 rendered - started, time.time() - rendered))


def check():
    problems = []
    with tempfile.TemporaryDirectory() as fresh:
        generate(fresh)
        wanted = sorted(f for f in os.listdir(fresh))
        have = sorted(f for f in os.listdir(OUT_DIR) if f != "README.md"
                      and os.path.isfile(os.path.join(OUT_DIR, f)))
        for name in sorted(set(wanted) | set(have)):
            if name not in have:
                problems.append("missing " + name)
            elif name not in wanted:
                problems.append("not generated " + name)
            elif not filecmp.cmp(os.path.join(fresh, name), os.path.join(OUT_DIR, name),
                                 shallow=False):
                problems.append("differs " + name)
    if problems:
        sys.exit("conformance/beatgrid is stale (python3 tools/beatgrid-vectors.py): "
                 + ", ".join(problems))
    print("conformance/beatgrid matches tools/beatgrid-vectors.py")


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif sys.argv[1:]:
        sys.exit("usage: python3 tools/beatgrid-vectors.py [--check]")
    else:
        generate(OUT_DIR)


if __name__ == "__main__":
    main()
