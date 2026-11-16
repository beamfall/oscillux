#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the version 4 beat tracker vectors under conformance/dsp/music/beat-v4/ (OSC-BEAT-V4).

An independent standard-library model of the beat-pointer tracker that
conformance/dsp/music/README.md ("Beat tracker, version 4") specifies. It shares no code with
crates/oscillux-core/src/dsp/beat_v4.rs. Creation evaluates exp and ln with the same
fixed-iteration series as the specification; the per-frame model uses only IEEE double
addition, subtraction, multiplication, division, absolute value and comparisons, accumulated in
the specified order (explicit loops, never sum()), so the Rust tracker must reproduce every
output bit for bit.

Each vector file uses the "dsp-beat-vectors v2" format of conformance/dsp/music/beat/: a
synthetic input stream (frame flags, low, mid and high onsets and every spectrum band, quantised
to n / 256 so they are exact), the configuration with "config behavior_version 4", every eighth
output row plus every beat row, and an FNV-1a digest over all output rows.

Usage: python3 tools/dsp-beat-v4-vectors.py
       python3 tools/dsp-beat-v4-vectors.py --check   (exit 1 if a generated file differs)
"""

import filecmp
import math
import os
import struct
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIR = os.path.join(ROOT, "conformance", "dsp", "music", "beat-v4")

FLAG_GAP, FLAG_STALLED = 1, 2
NEVER = (1 << 64) - 1   # "frames since activity" before any activity (saturating u64)

# Model constants (README, "Beat tracker, version 4").
SHORTEST_PERIOD = 8     # frames
LONGEST_PERIOD = 512    # frames
ENVELOPE_WEIGHTS = (2.0, 1.0, 1.0)   # low, mid, high onset
MEAN_SECONDS = 2.0      # running mean time constant of the envelope
MEAN_MULTIPLE = 3.0
MEAN_OFFSET = 1e-3
RATIO_OFFSET = 0.5      # r = (0.5 + x) / 1.5
WINDOW_FRACTION = 0.04  # observation half-width, fraction of the period
SHARPNESS = 100.0       # period transition weight exp(-100 |q' / q - 1|)
REACH = 3               # periods either side a transition reaches
UNIFORM_SHARE = 1e-6
PRIOR_CENTRE_BPM = 100.0
PRIOR_WIDTH = 0.6       # natural-log period
PRIOR_PER_SECOND = 2.0
JUMP_SHARE = 0.01
JUMP_REACH = 0.3        # natural-log period
ENVELOPE_LAG = 1.5      # frames
LATE_SLACK = 2.5        # frames
GATE = 0.5              # beat periods between beats, at least
ACTIVITY = 0.1
HOLD = 4                # beat periods after the last activity
NEIGHBOURS = 2          # periods (tempo, confidence) and phases (confidence) either side
BAR_DECAY = 0.95
BAR_EPSILON = 1e-9
BAR_WEIGHTS = (1.0, 0.5, 0.25, 0.5)   # interval level, low onset, change, bass flux
ONSET_FRAMES = 3
FLUX_BANDS = 3
FLUX_FRAMES = 3.0
MAX_BEATS_PER_BAR = 16
# Octave cue (README, "Octave cue").
OCTAVE_PENALTY = 0.05   # factor on a penalised period's moving mass
OCTAVE_DECAY = 0.95     # per sample
OCTAVE_HIGH_SHARE = 0.55
OCTAVE_LOW_SHARE = 0.4
OCTAVE_WARMUP = 8       # samples
# Downbeat stage (README, "Downbeat stage").
BAR_RESTART_RUN = 4     # beats at another metrical level before the statistics restart
BAR_HOLD = 1.1          # score factor that keeps the previous position

# Version 2 bass analysis shape (conformance/dsp/README.md, "Behaviour version 2"), for the
# spectrum lag of the bar stage.
BASS_RATE_HZ = 6000
BASS_WINDOW = 1024.0
BASS_CIC_ORDER = 4
BASS_TOP_FRACTION = 0.1
BASS_MAX_MAIN_BINS = 4.0
BASS_MAX_DECIMATION = 256


def exp_series(y):
    """e^y: halve y until |y| < 0.5, Horner-sum the Taylor series to degree 20, square back."""
    halvings = 0
    while abs(y) >= 0.5:
        y *= 0.5
        halvings += 1
    s = 1.0
    for n in range(20, 0, -1):
        s = 1.0 + y * s / float(n)
    for _ in range(halvings):
        s *= s
    return s


def ln_series(x):
    """ln x: scale by 2 into (sqrt(1/2), sqrt(2)], then 2 atanh((m - 1) / (m + 1)) to degree 25."""
    m, e = x, 0
    while m >= 2.0:
        m *= 0.5
        e += 1
    while m < 1.0:
        m *= 2.0
        e -= 1
    if m > 1.4142135623730951:
        m *= 0.5
        e += 1
    s = (m - 1.0) / (m + 1.0)
    s2 = s * s
    acc = 0.0
    for n in range(12, -1, -1):
        acc = 1.0 / float(2 * n + 1) + s2 * acc
    return 2.0 * s * acc + float(e) * 0.6931471805599453


def positive(v):
    return v if math.isfinite(v) and v > 0.0 else 0.0


def onset_input(v):
    v = positive(v)
    return v if v < 1.0 else 1.0


def spectrum_lag(cfg):
    """round(bass group delay / hop) frames when the version 2 bass analysis is on, else 0."""
    fs = cfg["sample_rate_hz"]
    window_main = cfg.get("fft_window_samples", 2048)
    hop = cfg["hop_samples"]
    lo_hz, hi_hz = cfg.get("spectrum_min_hz", 40.0), cfg.get("spectrum_max_hz", 16000.0)
    bands = cfg["spectrum_bands"]
    d = 1
    while fs > BASS_RATE_HZ * d:
        d *= 2
        if d > BASS_MAX_DECIMATION:
            return 0
    rate = fs / d
    length = min(math.floor(rate * BASS_WINDOW / BASS_RATE_HZ), BASS_WINDOW)
    # Band 0 must qualify (the edges are not near a threshold in these vectors).
    ratio = (hi_hz / lo_hz) ** (1.0 / bands)
    edge_lo, edge_hi = lo_hz, lo_hz * ratio
    qualifies = ((edge_hi - edge_lo) * window_main / fs < BASS_MAX_MAIN_BINS
                 and edge_hi <= BASS_TOP_FRACTION * rate)
    if not (length * d > window_main and qualifies):
        return 0
    aligned = window_main % d == 0 and hop % d == 0
    delay = ((length - 1) * d / 2.0 + (BASS_CIC_ORDER * (d - 1)) / 2.0
             + (0.0 if aligned else float(d - 1)))
    return int(math.floor(delay / hop + 0.5))


class BarStage:
    """Per bar position, decaying bias-corrected means of four beat features."""

    def __init__(self, bpb, lag, low_group, bands):
        self.bpb, self.lag, self.bands = bpb, lag, bands
        self.low = list(range(low_group[0], low_group[1] + 1))
        self.flux_bands = self.low[:FLUX_BANDS]
        self.clear()

    def clear(self):
        self.next_slot = 0
        self.closing_slot = 0
        self.any_closed = False
        self.acc = [[0.0] * 4 for _ in range(self.bpb)]
        self.wt = [[BAR_EPSILON] * 4 for _ in range(self.bpb)]
        self.level, self.count = 0.0, 0.0
        self.sums = [0.0] * self.bands
        self.previous_means = [0.0] * self.bands
        self.has_previous = False
        self.flux_peak, self.flux_last = 0.0, 0.0
        self.last_bands = [0.0] * len(self.flux_bands)
        self.onset_peak, self.onset_left, self.onset_last = 0.0, ONSET_FRAMES, 0.0
        self.onset_open = False
        self.history = [False] * (self.lag + 1)
        self.frame = 0
        self.reference = None
        self.run = 0
        self.held = 0

    def feed(self, slot, feature, value):
        self.acc[slot][feature] = self.acc[slot][feature] * BAR_DECAY + value
        self.wt[slot][feature] = self.wt[slot][feature] * BAR_DECAY + 1.0

    def step(self, spectrum, low_onset, beat, q):
        bpb = self.bpb
        if beat:
            ref = self.reference
            if ref is None or (3 * ref <= 4 * q and 3 * q <= 4 * ref):
                self.reference, self.run = q, 0
            else:
                self.run += 1
                if self.run >= BAR_RESTART_RUN:
                    self.acc = [[0.0] * 4 for _ in range(bpb)]
                    self.wt = [[BAR_EPSILON] * 4 for _ in range(bpb)]
                    self.reference, self.run = q, 0
        flux = 0.0
        for j, b in enumerate(self.flux_bands):
            v = positive(spectrum[b])
            rise = v - self.last_bands[j]
            if rise > 0.0:
                flux += rise
            else:
                flux += 0.0
            self.last_bands[j] = v
        if beat:
            if self.onset_open:
                self.feed((self.next_slot + bpb - 1) % bpb, 1, self.onset_peak)
            self.onset_peak, self.onset_left, self.onset_open = self.onset_last, 0, True
        if self.onset_left < ONSET_FRAMES:
            if low_onset > self.onset_peak:
                self.onset_peak = low_onset
            self.onset_left += 1
        self.onset_last = low_onset
        ring = len(self.history)
        self.history[self.frame % ring] = beat
        if self.frame >= self.lag and self.history[(self.frame - self.lag) % ring]:
            if self.count > 0.0 and self.any_closed:
                change = 0.0
                for b in range(self.bands):
                    mean = self.sums[b] / self.count
                    if self.has_previous:
                        change += abs(mean - self.previous_means[b])
                    self.previous_means[b] = mean
                slot = (self.closing_slot + bpb - 1) % bpb
                self.feed(slot, 0, self.level / self.count)
                self.feed(slot, 2, change)
                self.feed(slot, 3, self.flux_peak)
                self.has_previous = True
            self.closing_slot = (self.closing_slot + 1) % bpb
            self.any_closed = True
            self.level, self.count = 0.0, 0.0
            self.sums = [0.0] * self.bands
            self.flux_peak = self.flux_last
        if self.count < FLUX_FRAMES and flux > self.flux_peak:
            self.flux_peak = flux
        self.flux_last = flux
        position = None
        if beat:
            means = []
            for k in range(4):
                total = 0.0
                for i in range(bpb):
                    total += self.acc[i][k] / self.wt[i][k]
                means.append(total / float(bpb))
            best, best_score = 0, -sys.float_info.max
            scores = []
            for i in range(bpb):
                score = 0.0
                for k in range(4):
                    score += (BAR_WEIGHTS[k] * (self.acc[i][k] / self.wt[i][k])
                              / (means[k] + BAR_EPSILON))
                scores.append(score)
                if score > best_score:
                    best, best_score = i, score
            if scores[self.held] * BAR_HOLD >= best_score:
                best = self.held
            self.held = best
            position = (self.next_slot + bpb - best) % bpb
            self.next_slot = (self.next_slot + 1) % bpb
        for b in self.low:
            self.level += positive(spectrum[b])
        for b in range(self.bands):
            self.sums[b] += positive(spectrum[b])
        self.count += 1.0
        self.frame += 1
        return position


class BeatPointer:
    """Joint (period, phase) distribution; phase k of period q means beats at t = k (mod q)."""

    def __init__(self, cfg, beat_cfg):
        rate, hop = cfg["sample_rate_hz"], cfg["hop_samples"]
        self.fr = rate / hop
        shortest = math.floor(self.fr * 60.0 / beat_cfg["max_bpm"])
        longest = math.ceil(self.fr * 60.0 / beat_cfg["min_bpm"])
        assert SHORTEST_PERIOD <= shortest and longest <= LONGEST_PERIOD
        self.q = list(range(int(shortest), int(longest) + 1))
        n = len(self.q)
        self.start, total = [], 0
        for q in self.q:
            self.start.append(total)
            total += q
        self.size = total
        self.half_width = [int(math.floor(WINDOW_FRACTION * q)) for q in self.q]
        self.moves = []   # per source period: [(target index, weight)], targets ascending
        for j in range(n):
            targets = range(max(j - REACH, 0), min(j + REACH, n - 1) + 1)
            raw = [exp_series(-SHARPNESS * abs(self.q[i] / self.q[j] - 1.0)) for i in targets]
            norm = 0.0
            for w in raw:
                norm += w
            self.moves.append([(i, w / norm) for i, w in zip(targets, raw)])
        centre = self.fr * 60.0 / PRIOR_CENTRE_BPM
        self.prior = []
        for q in self.q:
            z = ln_series(q / centre) / PRIOR_WIDTH
            self.prior.append(exp_series(-0.5 * z * z * PRIOR_PER_SECOND * q / self.fr))
        self.reach = []
        for i in range(n):
            near = [j for j in range(n) if abs(ln_series(self.q[i] / self.q[j])) <= JUMP_REACH]
            self.reach.append((near[0], near[-1], float(near[-1] - near[0] + 1)))
        self.mean_rate = 1.0 / (MEAN_SECONDS * self.fr)
        self.bpb = beat_cfg["beats_per_bar"]
        self.bars = BarStage(self.bpb, spectrum_lag(cfg), cfg["onset_band_groups"][0],
                             cfg["spectrum_bands"])
        self.p = [0.0] * self.size
        self.marginal = [0.0] * n
        even = 1.0 / self.size
        for i, q in enumerate(self.q):
            self.marginal[i] = q * even
        self.frame, self.mean, self.locked = 0, 0.0, False
        self.forget()

    def forget(self):
        """Gap or stall: spread each period's mass evenly over its phases; forget the rest."""
        for i, q in enumerate(self.q):
            v = self.marginal[i] / q
            for k in range(q):
                self.p[self.start[i] + k] = v
        self.quiet = NEVER
        self.last_beat = None
        self.bar_pos = 0
        self.last_phase = 0.0
        self.bars.clear()
        self.ring_low = [0.0] * 4
        self.ring_high = [0.0] * 4
        self.clear_octave()

    def clear_octave(self):
        self.oct_low = [0.0] * 4
        self.oct_high = [0.0] * 4
        self.oct_samples = 0
        self.oct_beats = 0
        self.oct_beat_frame = 0
        self.oct_mid_frame = 0
        self.oct_anchor = None
        self.oct_period = None
        self.penalised_from = None

    def octave(self, t, q, e):
        """The octave cue: half-beat onset peaks of the best state's two-beat cycle."""
        old = self.oct_period
        if old is not None and 2 * old <= 5 * q <= 3 * old:
            for sums in (self.oct_low, self.oct_high):
                sums[:] = [0.5 * (sums[0] + sums[2]), 0.0, 0.5 * (sums[1] + sums[3]), 0.0]
            self.oct_anchor = (self.oct_beat_frame, old)
        elif old is not None and 17 * old <= 10 * q <= 23 * old:
            u, v = (0, 2) if self.oct_low[0] >= self.oct_low[2] else (2, 0)
            for sums in (self.oct_low, self.oct_high):
                sums[:] = [sums[u], sums[v], sums[u], sums[v]]
            self.oct_anchor = None
        elif old is None or 10 * q > 13 * old or 13 * q < 10 * old:
            self.clear_octave()
        self.oct_period = q
        # At most one sample per beat and per mid-beat: more than half a period since the last.
        if e == 2 and 2 * (t - self.oct_beat_frame) > q:
            if self.oct_anchor is not None:
                ta, qa = self.oct_anchor
                rho = (t - ta) % qa
                self.oct_beats = 1 if qa < 4 * rho < 3 * qa else 0
                self.oct_anchor = None
            else:
                self.oct_beats += 1
            self.oct_beat_frame = t
            pos = 2 * (self.oct_beats % 2)
        elif e == q // 2 + 2 and 2 * (t - self.oct_mid_frame) > q:
            self.oct_mid_frame = t
            pos = 2 * (self.oct_beats % 2) + 1
        else:
            return
        peak_low = peak_high = 0.0
        for j in range(4):
            if self.ring_low[j] > peak_low:
                peak_low = self.ring_low[j]
            if self.ring_high[j] > peak_high:
                peak_high = self.ring_high[j]
        for j in range(4):
            self.oct_low[j] *= OCTAVE_DECAY
            self.oct_high[j] *= OCTAVE_DECAY
        self.oct_low[pos] += peak_low
        self.oct_high[pos] += peak_high
        self.oct_samples += 1
        if self.oct_samples < OCTAVE_WARMUP:
            return
        lo, hi = self.oct_low, self.oct_high
        # Strict: all-zero sums (no high-band or no low-band onset) are no evidence.
        backbeat = (hi[1] + hi[3] > OCTAVE_HIGH_SHARE * (hi[0] + hi[2])
                    and lo[1] + lo[3] < OCTAVE_LOW_SHARE * (lo[0] + lo[2]))
        u, v = (0, 2) if lo[0] >= lo[2] else (2, 0)
        alternate = hi[v] > OCTAVE_HIGH_SHARE * hi[u] and lo[v] < OCTAVE_LOW_SHARE * lo[u]
        if backbeat and q // 2 >= self.q[0]:
            target = (3 * q) // 4
        elif alternate:
            target = (3 * q) // 2
        else:
            self.penalised_from = None
            return
        self.penalised_from = None
        for i, qi in enumerate(self.q):
            if qi >= target:
                self.penalised_from = i
                break

    def update(self, flags, low, mid, high, spectrum):
        if flags & (FLAG_GAP | FLAG_STALLED):
            self.forget()
        t = self.frame
        low = onset_input(low)
        envelope = (ENVELOPE_WEIGHTS[0] * low + ENVELOPE_WEIGHTS[1] * onset_input(mid)
                    + ENVELOPE_WEIGHTS[2] * onset_input(high))
        self.quiet = 0 if envelope >= ACTIVITY else min(self.quiet + 1, NEVER)
        self.mean += (envelope - self.mean) * self.mean_rate
        x = envelope / (MEAN_MULTIPLE * self.mean + MEAN_OFFSET)
        r = (RATIO_OFFSET + x) / (RATIO_OFFSET + 1.0)
        self.ring_low[t % 4] = low
        self.ring_high[t % 4] = onset_input(mid) + onset_input(high)
        n = len(self.q)
        # Observation: phases whose beat lies within the half-width of t.
        for i, q in enumerate(self.q):
            w = self.half_width[i]
            for lag in range(-w, w + 1):
                k = (t - lag) % q
                weight = 1.0 - abs(lag) / (w + 1.0)
                self.p[self.start[i] + k] *= 1.0 + (r - 1.0) * weight
        # Beat point: the phases at their beat move on to nearby periods.
        here = [self.start[i] + t % q for i, q in enumerate(self.q)]
        leaving = []
        for i in range(n):
            m = self.p[here[i]] * self.prior[i]
            if self.penalised_from is not None and i >= self.penalised_from:
                m *= OCTAVE_PENALTY
            leaving.append(m)
            self.p[here[i]] = 0.0
        for j in range(n):
            for i, w in self.moves[j]:
                self.p[here[i]] += leaving[j] * w * (1.0 - JUMP_SHARE)
        running = [0.0]
        for j in range(n):
            running.append(running[j] + leaving[j] / self.reach[j][2])
        for i in range(n):
            first, last, _ = self.reach[i]
            self.p[here[i]] += JUMP_SHARE * (running[last + 1] - running[first])
        total = 0.0
        for v in self.p:
            total += v
        scale, floor_share = (1.0 - UNIFORM_SHARE) / total, UNIFORM_SHARE / self.size
        for s in range(self.size):
            self.p[s] = self.p[s] * scale + floor_share
        # Most probable state, first on ties.
        top, bi, bk = -1.0, 0, 0
        for i, q in enumerate(self.q):
            mass = 0.0
            for k in range(q):
                v = self.p[self.start[i] + k]
                mass += v
                if v > top:
                    top, bi, bk = v, i, k
            self.marginal[i] = mass
        q = self.q[bi]
        elapsed = (t - bk) % q
        frames_since = elapsed + ENVELOPE_LAG
        if frames_since >= q:
            frames_since -= q
        signed = frames_since - q if frames_since > q / 2.0 else frames_since
        gated = self.last_beat is not None and float(t - self.last_beat) < GATE * q
        beat = (self.quiet <= HOLD * q and -0.5 < signed <= LATE_SLACK and not gated)
        if beat:
            self.last_beat, self.locked = t, True
        if self.quiet <= q:
            self.octave(t, q, elapsed)
        else:
            # Silence or a lost beat: the next song decides the octave afresh.
            self.clear_octave()
        position = self.bars.step(spectrum, low, beat, q)
        span = range(max(bi - NEIGHBOURS, 0), min(bi + NEIGHBOURS, n - 1) + 1)
        num = den = 0.0
        for i in span:
            num += self.marginal[i] * self.q[i]
            den += self.marginal[i]
        tempo = 60.0 * self.fr / (num / den)
        self.frame += 1
        if not self.locked:
            return (0.0, 0.0, 0.0, 0.0, 0, 0, 0)
        phase = 0.0 if beat and signed <= 0.0 else frames_since / q
        if position is not None:
            self.bar_pos = position
        elif phase < self.last_phase - 0.5:
            self.bar_pos = (self.bar_pos + 1) % self.bpb
        self.last_phase = phase
        near = 0.0
        for i in span:
            qi = self.q[i]
            centre = (t - elapsed) % qi
            for delta in range(-NEIGHBOURS, NEIGHBOURS + 1):
                near += self.p[self.start[i] + (centre + delta) % qi]
        quiet = float(self.quiet)
        if quiet <= q:
            fade = 1.0
        elif quiet >= HOLD * float(q):
            fade = 0.0
        else:
            fade = (HOLD * float(q) - quiet) / ((HOLD - 1) * float(q))
        confidence = (near if near < 1.0 else 1.0) * fade
        down = 1 if beat and self.bar_pos == 0 else 0
        return (tempo, phase, (self.bar_pos + phase) / self.bpb, confidence, int(beat), down,
                self.bar_pos)


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


def stream(spec):
    """Quantised rows [flags, low, mid, high, band...].

    Each beat has a kick in the low onset (0.85 on the first beat of the bar, else 0.5), a
    backbeat snare in the mid onset on odd beats and a tick in the high onset; a hat (mid 0.15,
    high 0.35) falls half a beat later. Onsets ring for one more frame at 0.4 of their height.
    The spectrum sits at 0.3 plus noise; bands 0-3 rise by 0.3 over the first beat interval of
    each bar and every band carries a short decaying burst after each beat."""
    cfg, bc = spec["config"], spec["beat"]
    fr = cfg["sample_rate_hz"] / cfg["hop_samples"]
    frames, bands, bpb = spec["frames"], cfg["spectrum_bands"], bc["beats_per_bar"]
    rng = Lcg(spec["seed"])
    hits, beat_frames, bar_frames = {}, [], set()
    t, i = 0.0, 0
    while t < frames:
        bpm = [b for first, b in spec["segments"] if t >= first][-1]
        period = fr * 60.0 / bpm
        n, slot = int(math.floor(t)), i % bpb
        hit = hits.setdefault(n, [0.0, 0.0, 0.0])
        hit[0] += 0.85 if slot == 0 else 0.5
        hit[1] += 0.6 if slot % 2 == 1 else 0.0
        hit[2] += 0.25
        hat = hits.setdefault(int(math.floor(t + 0.5 * period)), [0.0, 0.0, 0.0])
        hat[1] += 0.15
        hat[2] += 0.35
        beat_frames.append(n)
        if slot == 0:
            bar_frames.add(n)
        t += period
        i += 1
    beat_set = set(beat_frames)
    rows, in_first_beat, since_beat = [], False, 99
    silence = spec["events"].get("silence", [])
    for n in range(frames):
        if n in beat_set:
            in_first_beat = n in bar_frames
            since_beat = 0
        onset = list(hits.get(n, [0.0, 0.0, 0.0]))
        ring = hits.get(n - 1, [0.0, 0.0, 0.0])
        for g in range(3):
            onset[g] += 0.4 * ring[g] + 0.05 * rng.next()
        burst = 0.25 / (1 + since_beat) if since_beat < 4 else 0.0
        level = []
        for b in range(bands):
            v = 0.3 + 0.1 * rng.next() + burst
            if in_first_beat and b < 4:
                v += 0.3
            level.append(v)
        since_beat += 1
        if any(a <= n < b for a, b in silence):
            onset, level = [0.0, 0.0, 0.0], [0.0] * bands
        flags = spec["events"].get("flags", {}).get(n, 0)
        rows.append([flags] + [q256(v) for v in onset] + [q256(v) for v in level])
    return rows


VECTORS = (
    {
        "name": "beat-v4-default",
        "description": "behaviour version 4, default configuration (93.75 frames/s, spectrum lag "
                       "8 frames), 60-200 BPM, 4/4; 120 BPM, then 140 BPM from frame 900; gap "
                       "and stall at frame 1500; silence over frames 1600-1899; 100 BPM after it",
        "config": {"sample_rate_hz": 48000, "hop_samples": 512, "spectrum_bands": 24,
                   "onset_band_groups": ((0, 7), (8, 15), (16, 23))},
        "beat": {"min_bpm": 60.0, "max_bpm": 200.0, "beats_per_bar": 4},
        "frames": 2400, "segments": ((0, 120.0), (900, 140.0), (1900, 100.0)), "seed": 20261023,
        "events": {"flags": {1500: FLAG_GAP | FLAG_STALLED}, "silence": [(1600, 1900)]},
    },
    {
        "name": "beat-v4-config-16k",
        "description": "behaviour version 4, 16 kHz, hop 256 (62.5 frames/s, spectrum lag 5 "
                       "frames), 16 bands, low group 0-4, 60-200 BPM, 3/4; 90 BPM, then 174 BPM "
                       "from frame 1000; gap at frame 1500",
        "config": {"sample_rate_hz": 16000, "hop_samples": 256, "spectrum_bands": 16,
                   "fft_window_samples": 1024, "spectrum_min_hz": 50.0,
                   "spectrum_max_hz": 7000.0,
                   "onset_band_groups": ((0, 4), (5, 10), (11, 15))},
        "beat": {"min_bpm": 60.0, "max_bpm": 200.0, "beats_per_bar": 3},
        "frames": 2000, "segments": ((0, 90.0), (1000, 174.0)), "seed": 79,
        "events": {"flags": {1500: FLAG_GAP}},
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
    rows = stream(spec)
    tracker = BeatPointer(cfg, bc)
    lines = [
        "# dsp-beat-vectors v2",
        "# %s: %s" % (spec["name"], spec["description"]),
        "# expected values: tools/dsp-beat-v4-vectors.py (independent oracle); floats are shortest "
        "round-trip decimal",
        "config behavior_version 4",
    ]
    lines += ["config %s %s" % (k, config_value(v)) for k, v in cfg.items()]
    lines += ["beat_config %s %s" % (k, config_value(v)) for k, v in bc.items()]
    lines.append("# in flags onset_low onset_mid onset_high spectrum[%d] (each value n / 256)"
                 % cfg["spectrum_bands"])
    lines += ["in " + " ".join(str(v) for v in row) for row in rows]
    lines.append("# out frame tempo_bpm beat_phase bar_phase confidence beat downbeat "
                 "beat_in_bar (every 8th frame and every beat)")
    digest, beats, downbeats = 0xcbf29ce484222325, 0, 0
    for n, row in enumerate(rows):
        out = tracker.update(row[0], row[1] / 256.0, row[2] / 256.0, row[3] / 256.0,
                             [v / 256.0 for v in row[4:]])
        digest = fnv1a(struct.pack("<4d3I", *out), digest)
        beats += out[4]
        downbeats += out[5]
        if n % 8 == 0 or out[4]:
            lines.append("out %d %s %d %d %d" % (n, " ".join(repr(v) for v in out[:4]), *out[4:]))
    lines.append("digest %016x" % digest)
    print("%-20s %d frames, %d beats, %d downbeats, digest %016x"
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
        sys.exit("conformance/dsp/music/beat-v4/ differs from the oracle output (changed, missing "
                 "or extra: %s); regenerate it" % ", ".join(problems))
    print("conformance/dsp/music/beat-v4/: %d files match the oracle" % len(wanted))


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif sys.argv[1:]:
        sys.exit("usage: python3 tools/dsp-beat-v4-vectors.py [--check]")
    else:
        generate(OUT_DIR)


if __name__ == "__main__":
    main()
