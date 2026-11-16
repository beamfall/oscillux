#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the beat tracker vectors under conformance/dsp/music/beat/ (OSC-DSP-BEAT).

An independent standard-library model of the streaming tempo, beat and downbeat tracker that
conformance/dsp/music/README.md ("Beat tracker") specifies. It shares no code with
crates/oscillux-core/src/dsp/beat.rs. It uses only IEEE double addition, subtraction,
multiplication, division, floor, absolute value and comparisons, so the Rust tracker must
reproduce every output bit for bit.

Each vector file holds a synthetic input stream (frame flags, low and mid onsets, the high
onset for version 3, and the low-group bands, quantised to n / 256 so they are exact), the
configuration, every eighth output row plus every beat row, and an FNV-1a digest over all output
rows. Version 1 files ("dsp-beat-vectors v1") cover behaviour versions 1 and 2, whose trackers
are the same; version 2 files cover behaviour version 3 ("Beat tracker, version 3").

Usage: python3 tools/dsp-beat-vectors.py
       python3 tools/dsp-beat-vectors.py --check   (exit 1 if a generated file differs)
"""

import filecmp
import math
import os
import struct
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIR = os.path.join(ROOT, "conformance", "dsp", "music", "beat")

FLAG_GAP, FLAG_STALLED = 1, 2

# Tracker constants (README, "Beat tracker").
PICK_RING = 16          # onset function history, frames (a power of two)
PICK_DELAY = 2          # the picker decides on frame t - 2
PICK_MAX_BEFORE = 3     # local maximum over k-3 .. k+2
PICK_MEAN_BEFORE = 10   # mean over k-10 .. k+2
PICK_FILLED = PICK_MEAN_BEFORE + PICK_DELAY + 1
PICK_DELTA = 0.1
PICK_RATIO = 3.0
PICK_MIN_GAP = 3        # frames between picked onsets
ONSET_RING = 24         # previous onsets paired for inter-onset intervals
KERNEL = 2              # triangular deposit half-width, frames
HARMONICS = 4           # comb harmonics
IOI_TAU_S = 2.0         # inter-onset histogram time constant
PRIOR_WEIGHT = 1.0      # tempo prior around a period of half a second (120 BPM)
FOLLOW = 0.06           # relative period change followed at once
SWITCH_S = 0.5          # a new period must persist this long (twice as long for the first lock)
JUMP_MARGIN = 1.2       # a jump candidate must outscore the current period by this factor
PHASE_BINS = 48
PHASE_BEATS = 8.0       # phase histogram time constant, beat periods
HALF_WEIGHT = 0.5       # weight of the bin half a beat on in a phase score
PHASE_TRACK = 4         # bins either side of the anchor searched for its own peak
PHASE_SWITCH = 1.3      # a distant phase peak must beat the anchor's by this factor
FREE_BEATS = 4.0        # beats after a period jump or reset before that hysteresis applies
JUMP_KEEP = 0.5         # phase weight kept on a period jump
BEAT_GATE = 0.5         # beat periods between emitted beats, at least
CUE_SPAN = 3            # downbeat cue: low-band change from beat - 3 to beat + 3 frames
SPEC_RING = 8           # low-band history, frames (a power of two, > 2 * CUE_SPAN)
ACCENT_RATE = 0.3
ACCENT_SWITCH = 1.1
FLUSH = 1e-12           # histogram values below this become 0
MIN_PERIOD_FRAMES = 8
MAX_PERIOD_FRAMES = 1024
MAX_BEATS_PER_BAR = 16

# Version 3 (README, "Beat tracker, version 3").
V3_PRIOR_BPM = 110.0
V3_PRIOR_WEIGHT = 1.5
V3_ACF_TAU_S = 4.0      # correlation histogram time constant
V3_MEAN_SCALE = 1.5     # multiple of the running mean subtracted from the envelope
V3_MEAN_TAU_S = 1.0     # running mean of the correlation envelope


def floor(x):
    return float(math.floor(x))


def frac(x):
    """x - floor(x), with a result that rounds up to 1 returned as 0."""
    f = x - floor(x)
    return 0.0 if f >= 1.0 else f


def clean(v):
    """Finite positive inputs pass; anything else reads as 0."""
    return v if math.isfinite(v) and v > 0.0 else 0.0


class BeatTracker:
    def __init__(self, sample_rate_hz, hop_samples, low_group, min_bpm, max_bpm, beats_per_bar,
                 version=1):
        self.v3 = version == 3
        self.fr = sample_rate_hz / hop_samples
        self.lo = int(floor(self.fr * 60.0 / max_bpm))
        self.hi = int(-floor(-(self.fr * 60.0 / min_bpm)))
        assert MIN_PERIOD_FRAMES <= self.lo <= self.hi <= MAX_PERIOD_FRAMES
        assert 1 <= beats_per_bar <= MAX_BEATS_PER_BAR
        self.bpb = beats_per_bar
        self.g0, self.g1 = low_group
        self.ioi_decay = 1.0 - 1.0 / ((V3_ACF_TAU_S if self.v3 else IOI_TAU_S) * self.fr)
        self.switch = int(floor(SWITCH_S * self.fr + 0.5))
        self.pref = self.fr * 60.0 / V3_PRIOR_BPM if self.v3 else self.fr * 0.5
        self.hist = [0.0] * (HARMONICS * self.hi + 2 * KERNEL + 1)
        self.x = [0.0] * PICK_RING
        self.low = [0.0] * PICK_RING
        self.zrate = 1.0 / (V3_MEAN_TAU_S * self.fr)
        self.z = [0.0] * (HARMONICS * self.hi + KERNEL + 1) if self.v3 else []
        self.spec = [[0.0] * (self.g1 - self.g0 + 1) for _ in range(SPEC_RING)]
        self.t = 0
        self.period = 0.0
        self.pending = 0.0
        self.count = 0
        self.clock = 0.0
        self.last_beat = None
        self.soft_reset()

    def soft_reset(self):
        """After a gap or stall: forget onsets, phase and bar position; keep the tempo."""
        self.filled = 0
        self.last_onset = None
        self.ring = [None] * ONSET_RING
        self.rpos = 0
        self.z = [0.0] * len(self.z)
        self.zmean = 0.0
        self.ph = [0.0] * PHASE_BINS
        self.prev_psi = None
        self.anchor = 0.0
        self.free = FREE_BEATS * self.period
        self.cue = None
        self.accent = [0.0] * self.bpb
        self.down = 0
        self.slot = self.bpb - 1

    def pick(self, t):
        """Strength of an onset at frame t - 2, or 0."""
        if self.filled < PICK_FILLED:
            return 0.0
        x, k = self.x, t - PICK_DELAY
        v = x[k % PICK_RING]
        for d in range(-PICK_MAX_BEFORE, PICK_DELAY + 1):
            if d != 0 and x[(k + d) % PICK_RING] > v:
                return 0.0
        total = 0.0
        for d in range(-PICK_MEAN_BEFORE, PICK_DELAY + 1):
            total += x[(k + d) % PICK_RING]
        mean = total / float(PICK_MEAN_BEFORE + PICK_DELAY + 1)
        if v < mean + PICK_DELTA or v < PICK_RATIO * mean:
            return 0.0
        if self.last_onset is not None and k - self.last_onset < PICK_MIN_GAP:
            return 0.0
        self.last_onset = k
        return v - mean

    def deposit(self, k, s):
        h, top = self.hist, HARMONICS * self.hi + KERNEL
        norm = float((KERNEL + 1) * (KERNEL + 1))
        for entry in self.ring:
            if entry is None:
                continue
            lag = k - entry[0]
            if lag < self.lo - KERNEL or lag > top:
                continue
            w = s * entry[1] / norm
            for d in range(-KERNEL, KERNEL + 1):
                h[lag + d] += w * float(KERNEL + 1 - abs(d))
        self.ring[self.rpos] = (k, s)
        self.rpos = (self.rpos + 1) % ONSET_RING

    def correlate(self, t, low, mid, high):
        """Version 3: this frame's envelope value times each remembered one, by lag."""
        raw = clean(low) + clean(mid) + clean(high)
        self.zmean += self.zrate * (raw - self.zmean)
        d = raw - V3_MEAN_SCALE * self.zmean
        v = d if d > 0.0 else 0.0
        z, n = self.z, len(self.z)
        i = t % n
        z[i] = v
        if v > 0.0:
            for lag in range(self.lo - KERNEL, HARMONICS * self.hi + KERNEL + 1):
                self.hist[lag] += v * z[(i - lag) % n]

    def comb_score(self, p):
        total = 0.0
        if self.v3:
            h = self.hist
            for n in range(1, HARMONICS + 1):
                total += max(h[n * p - 1], h[n * p], h[n * p + 1])
            r = (float(p) - self.pref) / (float(p) + self.pref)
            return total / (1.0 + V3_PRIOR_WEIGHT * r * r)
        for n in range(1, HARMONICS + 1):
            total += self.hist[n * p]
        r = (float(p) - self.pref) / self.pref
        return total / (1.0 + PRIOR_WEIGHT * r * r)

    def comb(self):
        """(candidate period in frames or 0, tempo contrast, the candidate's score)."""
        best, bp, total = -1.0, 0, 0.0
        for p in range(self.lo, self.hi + 1):
            score = self.comb_score(p)
            total += score
            if score > best:
                best, bp = score, p
        if best <= 0.0:
            return 0.0, 0.0, 0.0
        contrast = (best - total / float(self.hi - self.lo + 1)) / best
        if self.lo < bp < self.hi:
            y0, y2 = self.comb_score(bp - 1), self.comb_score(bp + 1)
            den = y0 - 2.0 * best + y2
            if den < 0.0:
                return float(bp) + 0.5 * (y0 - y2) / den, contrast, best
        return float(bp), contrast, best

    def follow(self, cand):
        if cand <= 0.0:
            self.pending, self.count = 0.0, 0
            return
        if self.period > 0.0 and abs(cand - self.period) <= FOLLOW * self.period:
            self.period, self.count = cand, 0
            return
        if self.count > 0 and abs(cand - self.pending) <= FOLLOW * self.pending:
            self.count += 1
        else:
            self.count = 1
        self.pending = cand
        need = self.switch if self.period > 0.0 else 2 * self.switch
        if self.count >= need:
            self.period, self.count = cand, 0
            # Phases measured at the old period no longer line up with the clock.
            for i in range(PHASE_BINS):
                v = self.ph[i] * JUMP_KEEP
                self.ph[i] = 0.0 if v < FLUSH else v
            self.free = FREE_BEATS * cand

    def smoothed(self, i):
        ph, n = self.ph, PHASE_BINS
        return ph[(i + n - 1) % n] + 2.0 * ph[i % n] + ph[(i + 1) % n]

    def phase_score(self, i):
        return self.smoothed(i) + HALF_WEIGHT * self.smoothed(i + PHASE_BINS // 2)

    def update(self, flags, low, mid, bands, high=0.0):
        """One frame in; (tempo_bpm, beat_phase, bar_phase, confidence, beat, downbeat,
        beat_in_bar) out."""
        if flags & (FLAG_GAP | FLAG_STALLED):
            self.soft_reset()
        t = self.t
        self.x[t % PICK_RING] = (clean(low) + 2.0 * clean(mid)) / 3.0
        self.low[t % PICK_RING] = clean(low)
        row = self.spec[t % SPEC_RING]
        for q in range(self.g1 - self.g0 + 1):
            row[q] = clean(bands[self.g0 + q])
        self.filled += 1
        s = self.pick(t)

        h, d = self.hist, self.ioi_decay
        for i in range(len(h)):
            v = h[i] * d
            h[i] = 0.0 if v < FLUSH else v
        if self.v3:
            self.correlate(t, low, mid, high)
        elif s > 0.0:
            self.deposit(t - PICK_DELAY, s)
        cand, tempo_contrast, score = self.comb()
        # A jump away from the current period counts only while the candidate clearly wins.
        if (self.period > 0.0 and cand > 0.0 and abs(cand - self.period) > FOLLOW * self.period
                and score < JUMP_MARGIN * self.comb_score(int(floor(self.period + 0.5)))):
            cand = self.period
        self.follow(cand)

        p = self.period
        if p <= 0.0:
            self.t += 1
            return (0.0, 0.0, 0.0, 0.0, 0, 0, 0)

        self.clock = frac(self.clock + 1.0 / p)
        if self.free > 0.0:
            self.free -= 1.0
        ph, decay = self.ph, 1.0 - 1.0 / (PHASE_BEATS * p)
        for i in range(PHASE_BINS):
            v = ph[i] * decay
            ph[i] = 0.0 if v < FLUSH else v
        if self.v3:
            # Every frame's low onset, plus the picked strength, votes for the phase.
            s = s + self.low[(t - PICK_DELAY) % PICK_RING] if self.filled > PICK_DELAY else 0.0
        if s > 0.0:
            pos = frac(self.clock - float(PICK_DELAY) / p) * float(PHASE_BINS)
            i0 = int(floor(pos))
            w = pos - float(i0)
            ph[i0 % PHASE_BINS] += s * (1.0 - w)
            ph[(i0 + 1) % PHASE_BINS] += s * w

        best, bi, total = -1.0, 0, 0.0
        for i in range(PHASE_BINS):
            v = self.phase_score(i)
            total += v
            if v > best:
                best, bi = v, i
        # The anchor follows its own peak and jumps to a distant one only when that is clearly
        # stronger.
        near = int(floor(self.anchor * float(PHASE_BINS) + 0.5))
        local, li = -1.0, 0
        for i in range(near + PHASE_BINS - PHASE_TRACK, near + PHASE_BINS + PHASE_TRACK + 1):
            v = self.phase_score(i % PHASE_BINS)
            if v > local:
                local, li = v, i % PHASE_BINS
        peak, pi = (local, li) if self.free <= 0.0 and PHASE_SWITCH * local >= best else (best, bi)
        y0, y2 = self.phase_score(pi + PHASE_BINS - 1), self.phase_score(pi + 1)
        den = y0 - 2.0 * peak + y2
        offset = 0.5 * (y0 - y2) / den if den < 0.0 else 0.0
        if best > 0.0:
            # An empty histogram (long silence) keeps the last peak.
            self.anchor = frac((float(pi) + offset) / float(PHASE_BINS))
        psi = frac(self.clock - self.anchor)
        phase_contrast = (best - total / float(PHASE_BINS)) / best if best > 0.0 else 0.0

        if self.last_onset is None:
            fresh = 0.0
        else:
            since = float(t - self.last_onset)
            if since <= 2.0 * p:
                fresh = 1.0
            elif since >= 16.0 * p:
                fresh = 0.0
            else:
                fresh = (16.0 * p - since) / (14.0 * p)

        beat = downbeat = 0
        prev = self.prev_psi
        if prev is not None and psi < prev and prev - psi > 0.5:
            # A forward wrap always moves the bar position on; it emits a beat only when gated.
            self.slot = (self.slot + 1) % self.bpb
            if (best > 0.0 and fresh > 0.0
                    and (self.last_beat is None or float(t - self.last_beat) >= BEAT_GATE * p)):
                beat = 1
                self.last_beat = t
                downbeat = int(self.slot == self.down)
                self.cue = (t + CUE_SPAN, self.slot)
        elif prev is not None and psi > prev and psi - prev > 0.5:
            # The phase estimate stepped back across 0: so does the bar position.
            self.slot = (self.slot + self.bpb - 1) % self.bpb
        self.prev_psi = psi

        if self.cue is not None and self.cue[0] <= t:
            slot = self.cue[1]
            self.cue = None
            if self.filled > 2 * CUE_SPAN:
                now, then = self.spec[t % SPEC_RING], self.spec[(t - 2 * CUE_SPAN) % SPEC_RING]
                change = 0.0
                for q in range(self.g1 - self.g0 + 1):
                    change += abs(now[q] - then[q])
                self.accent[slot] += ACCENT_RATE * (change - self.accent[slot])
                strongest = 0
                for q in range(1, self.bpb):
                    if self.accent[q] > self.accent[strongest]:
                        strongest = q
                if self.accent[strongest] > ACCENT_SWITCH * self.accent[self.down]:
                    self.down = strongest

        in_bar = (self.slot + self.bpb - self.down) % self.bpb
        self.t += 1
        return (60.0 * self.fr / p, psi, (float(in_bar) + psi) / float(self.bpb),
                tempo_contrast * phase_contrast * fresh, beat, downbeat, in_bar)


# --- Synthetic input streams --------------------------------------------------------------------

class Lcg:
    """The 64-bit LCG of conformance/dsp/README.md: uniform values in [0, 1)."""

    def __init__(self, seed):
        self.state = seed

    def next(self):
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return (self.state >> 11) / 2.0 ** 53


def q256(v):
    return max(0, min(256, int(math.floor(v * 256.0 + 0.5))))


def stream(frames, fr, segments, bands, beats_per_bar, seed, events, high=False):
    """Quantised input rows: [flags, low, mid, band...] per frame, or [flags, low, mid, high,
    band...] with high, where the high onset carries every beat at 0.3 and the hat at 0.2.

    segments: (first frame, bpm) tempo changes. Every beat has a low onset (stronger on the
    first beat of the bar), even beats after the first add a mid onset (a snare), and a weaker
    mid onset falls half a beat later (a hat). Each onset rings for one more frame at 0.4 of its
    height. One of bands 0-3 is raised by 0.35, a different one each bar. events: "flags" maps a frame to its
    flags; "silence" lists [first, end) ranges of all-zero input."""
    rng = Lcg(seed)
    beat_at, t, i = [], 0.0, 0
    while t < frames:
        bpm = segments[0][1]
        for first, b in segments:
            if t >= first:
                bpm = b
        period = fr * 60.0 / bpm
        beat_at.append((t, i, period))
        t += period
        i += 1
    onsets, bar_lines = {}, set()
    for t, i, period in beat_at:
        n, slot = int(math.floor(t)), i % beats_per_bar
        hit = onsets.setdefault(n, [0.0, 0.0, 0.0])
        hit[0] += 0.9 if slot == 0 else 0.55
        if slot % 2 == 1:
            hit[1] += 0.7
        hit[2] += 0.3
        hat = onsets.setdefault(int(math.floor(t + 0.5 * period)), [0.0, 0.0, 0.0])
        hat[1] += 0.3
        hat[2] += 0.2
        if slot == 0:
            bar_lines.add(n)
    rows, bar = [], -1
    for n in range(frames):
        if n in bar_lines:
            bar += 1
        low, mid, hi = onsets.get(n, [0.0, 0.0, 0.0])
        prev = onsets.get(n - 1, [0.0, 0.0, 0.0])
        low += 0.4 * prev[0] + 0.06 * rng.next()
        mid += 0.4 * prev[1] + 0.06 * rng.next()
        if high:
            hi += 0.4 * prev[2] + 0.06 * rng.next()
        level = [0.35 + 0.1 * rng.next() for _ in range(bands)]
        level[max(bar, 0) % 4] += 0.35
        flags = events.get("flags", {}).get(n, 0)
        if any(a <= n < b for a, b in events.get("silence", [])):
            low = mid = hi = 0.0
            level = [0.0] * bands
        onset = [q256(low), q256(mid)] + ([q256(hi)] if high else [])
        rows.append([flags] + onset + [q256(v) for v in level])
    return rows


VECTORS = (
    {
        "name": "beat-default",
        "description": "default configuration (93.75 frames/s), 4/4; 120 BPM, then 100 BPM from "
                       "frame 1100; gap and stall at frame 1700; silence over frames 2000-3099, longer than "
                       "sixteen beats",
        "config": {"sample_rate_hz": 48000, "hop_samples": 512, "spectrum_bands": 24,
                   "onset_band_groups": ((0, 7), (8, 15), (16, 23))},
        "beat": {"min_bpm": 80.0, "max_bpm": 160.0, "beats_per_bar": 4},
        "frames": 3400, "segments": ((0, 120.0), (1100, 100.0)), "seed": 20261020,
        "events": {"flags": {1700: FLAG_GAP | FLAG_STALLED},
                   "silence": [(2000, 3100)]},
    },
    {
        "name": "beat-config-32k",
        "description": "32 kHz, hop 256 (125 frames/s), 16 bands, low group 0-4, 60-120 BPM, 3/4; "
                       "90 BPM, then 105 BPM from frame 1000; gap at frame 1400",
        "config": {"sample_rate_hz": 32000, "hop_samples": 256, "spectrum_bands": 16,
                   "fft_window_samples": 1024, "spectrum_min_hz": 50.0,
                   "spectrum_max_hz": 12000.0,
                   "onset_band_groups": ((0, 4), (5, 10), (11, 15))},
        "beat": {"min_bpm": 60.0, "max_bpm": 120.0, "beats_per_bar": 3},
        "frames": 2000, "segments": ((0, 90.0), (1000, 105.0)), "seed": 77,
        "events": {"flags": {1400: FLAG_GAP}},
    },
    {
        "name": "beat-v3-default",
        "version": 3,
        "description": "behaviour version 3, default configuration (93.75 frames/s), 60-200 BPM, "
                       "4/4; 120 BPM, then 100 BPM from frame 1500; gap and stall at frame 2400; "
                       "silence over frames 2700-3799, after which it holds double tempo for a "
                       "few seconds",
        "config": {"sample_rate_hz": 48000, "hop_samples": 512, "spectrum_bands": 24,
                   "onset_band_groups": ((0, 7), (8, 15), (16, 23))},
        "beat": {"min_bpm": 60.0, "max_bpm": 200.0, "beats_per_bar": 4},
        "frames": 4800, "segments": ((0, 120.0), (1500, 100.0)), "seed": 20261021,
        "events": {"flags": {2400: FLAG_GAP | FLAG_STALLED},
                   "silence": [(2700, 3800)]},
    },
    {
        "name": "beat-v3-config-32k",
        "version": 3,
        "description": "behaviour version 3, 32 kHz, hop 256 (125 frames/s), 16 bands, low group "
                       "0-4, 60-200 BPM, 3/4; 72 BPM (tracked at double tempo), then 174 BPM from "
                       "frame 1600; gap at frame 2600",
        "config": {"sample_rate_hz": 32000, "hop_samples": 256, "spectrum_bands": 16,
                   "fft_window_samples": 1024, "spectrum_min_hz": 50.0,
                   "spectrum_max_hz": 12000.0,
                   "onset_band_groups": ((0, 4), (5, 10), (11, 15))},
        "beat": {"min_bpm": 60.0, "max_bpm": 200.0, "beats_per_bar": 3},
        "frames": 3200, "segments": ((0, 72.0), (1600, 174.0)), "seed": 78,
        "events": {"flags": {2600: FLAG_GAP}},
    },
)


def config_value(v):
    if isinstance(v, tuple):
        return ",".join("%d-%d" % g for g in v)
    return repr(v) if isinstance(v, float) else str(v)


def fnv1a(data, h=0xcbf29ce484222325):
    for byte in data:
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def vector_text(spec):
    cfg, bc = spec["config"], spec["beat"]
    fr = cfg["sample_rate_hz"] / cfg["hop_samples"]
    g0, g1 = cfg["onset_band_groups"][0]
    version = spec.get("version", 1)
    v3 = version == 3
    rows = stream(spec["frames"], fr, spec["segments"], cfg["spectrum_bands"],
                  bc["beats_per_bar"], spec["seed"], spec["events"], high=v3)
    tracker = BeatTracker(cfg["sample_rate_hz"], cfg["hop_samples"], (g0, g1), bc["min_bpm"],
                          bc["max_bpm"], bc["beats_per_bar"], version)
    lines = [
        "# dsp-beat-vectors v2" if v3 else "# dsp-beat-vectors v1",
        "# %s: %s" % (spec["name"], spec["description"]),
        "# expected values: tools/dsp-beat-vectors.py (independent oracle); floats are shortest "
        "round-trip decimal",
    ]
    if v3:
        lines.append("config behavior_version 3")
    lines += ["config %s %s" % (k, config_value(v)) for k, v in cfg.items()]
    lines += ["beat_config %s %s" % (k, config_value(v)) for k, v in bc.items()]
    lines.append("# in flags onset_low onset_mid %sspectrum[%d] (each value n / 256)"
                 % ("onset_high " if v3 else "", cfg["spectrum_bands"]))
    lines += ["in " + " ".join(str(v) for v in row) for row in rows]
    lines.append("# out frame tempo_bpm beat_phase bar_phase confidence beat downbeat "
                 "beat_in_bar (every 8th frame and every beat)")
    digest, beats, downbeats = 0xcbf29ce484222325, 0, 0
    for n, row in enumerate(rows):
        first = 4 if v3 else 3
        bands = [v / 256.0 for v in row[first:]]
        high = row[3] / 256.0 if v3 else 0.0
        out = tracker.update(row[0], row[1] / 256.0, row[2] / 256.0, bands, high)
        digest = fnv1a(struct.pack("<4d3I", *out), digest)
        beats += out[4]
        downbeats += out[5]
        if n % 8 == 0 or out[4]:
            lines.append("out %d %s %d %d %d" % (n, " ".join(repr(v) for v in out[:4]), *out[4:]))
    lines.append("digest %016x" % digest)
    print("%-16s %d frames, %d beats, %d downbeats, digest %016x"
          % (spec["name"], len(rows), beats, downbeats, digest))
    return "\n".join(lines) + "\n"


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for spec in VECTORS:
        with open(os.path.join(out_dir, spec["name"] + ".vectors"), "w") as handle:
            handle.write(vector_text(spec))


def check():
    with tempfile.TemporaryDirectory() as fresh:
        generate(fresh)
        wanted = sorted(os.listdir(fresh))
        have = sorted(os.listdir(OUT_DIR)) if os.path.isdir(OUT_DIR) else []
        _, changed, errors = filecmp.cmpfiles(fresh, OUT_DIR, wanted, shallow=False)
        extra = [n for n in have if n not in wanted]
        problems = changed + errors + extra
    if problems:
        sys.exit("conformance/dsp/music/beat/ differs from the oracle output (changed, missing or "
                 "extra: %s); regenerate it" % ", ".join(problems))
    print("conformance/dsp/music/beat/: %d files match the oracle" % len(wanted))


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif sys.argv[1:]:
        sys.exit("usage: python3 tools/dsp-beat-vectors.py [--check]")
    else:
        generate(OUT_DIR)


if __name__ == "__main__":
    main()
