#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Independent model of the reaction sampler, written from conformance/reaction/README.md.

It never reads Rust output: it builds deterministic scenarios, runs them through this model and
writes the expected results to conformance/reaction/vectors.json, which
crates/oscillux-core/tests/reaction_vectors.rs replays against the core.

Usage (standard library only, run with python3 -I):
       python3 tools/reaction-vectors.py           (write conformance/reaction/vectors.json)
       python3 tools/reaction-vectors.py --check   (exit 1 if vectors.json would change)
"""

import json
import math
import os
import struct
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
VECTORS = os.path.join(ROOT, "conformance", "reaction", "vectors.json")

AMPLITUDE, LEVEL, BASS, MID, TREBLE, ONSET, BASS_IMPACT, FLUX, CENTROID = range(9)
TRANSIENTS = (ONSET, BASS_IMPACT, FLUX)
CONTINUOUS = (AMPLITUDE, LEVEL, BASS, MID, TREBLE, CENTROID)
BINS = 64
MAX_CAPACITY = 1 << 16
MAX_BPB = 16
LATENCY = {1: (10.6, 16.0), 2: (7.7, 13.3), 3: (7.7, 13.3), 4: (7.7, 13.3)}
TOLERANCE = 1e-12
HOP_MS = 512 / 48


def default_config():
    return {
        "struct_size": 96, "capacity": 256, "output_latency_ms": 0.0,
        "display_latency_ms": 0.0, "render_ahead_ms": 0.0,
        "analysis_latency_ms": LATENCY[3][0], "onset_latency_ms": LATENCY[3][1],
        "onset_release_ms": 60.0, "bass_impact_release_ms": 150.0, "flux_release_ms": 60.0,
        "pulse_decay_ms": 1000.0 / 9.0, "pulse_rise_ms": 30.0, "phase_lock_gain": 0.1,
    }


def for_dsp(version, rate):
    if version not in LATENCY or rate == 0:
        return None
    scale = 48000.0 / rate
    return LATENCY[version][0] * scale, LATENCY[version][1] * scale


def finite(x):
    return math.isfinite(x)


def valid_config(c):
    times = [c[k] for k in ("output_latency_ms", "display_latency_ms", "render_ahead_ms",
                            "analysis_latency_ms", "onset_latency_ms")]
    rates = [c[k] for k in ("onset_release_ms", "bass_impact_release_ms", "flux_release_ms",
                            "pulse_decay_ms", "pulse_rise_ms")]
    return (c["struct_size"] == 96 and 1 <= c["capacity"] <= MAX_CAPACITY
            and all(finite(v) and v >= 0 for v in times)
            and all(finite(v) and v > 0 for v in rates)
            and 0 <= c["phase_lock_gain"] <= 1)


def frac(x):
    return x - math.floor(x)


def wrap(x):
    return x - math.floor(x + 0.5)


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


class Ref:
    def __init__(self, origin, tempo, beats, bar_beats, bpb, confidence, active):
        self.origin, self.tempo, self.beats, self.bar_beats = origin, tempo, beats, bar_beats
        self.bpb, self.confidence, self.active = bpb, confidence, active

    def per_ms(self):
        return self.tempo / 60000.0

    def beats_at(self, x):
        return self.beats + (x - self.origin) * self.per_ms()

    def bar_at(self, x):
        return self.bar_beats + (x - self.origin) * self.per_ms()


class Model:
    def __init__(self, config):
        self.c = config
        self.reset()

    def reset(self):
        self.queue = []          # [m, values, spectrum, beat, used_for_transients]
        self.current = None
        self.last_pushed = -math.inf
        self.peaks = [[0.0, -math.inf, None] for _ in TRANSIENTS]
        self.previous_onset = 0.0
        self.lock_offset = 0.0
        self.tracker = None
        self.clock = None
        self.follower = None     # [last_t, beats, in_bar, pulsed, pulsed_down, rate, correction]
        self.resync = True

    def releases(self):
        return (self.c["onset_release_ms"], self.c["bass_impact_release_ms"],
                self.c["flux_release_ms"])

    def push(self, m, values, spectrum, beat):
        bad_beat = beat is not None and not (
            all(finite(beat[k]) for k in ("tempo_bpm", "beat_phase", "bar_phase", "confidence"))
            and beat["tempo_bpm"] >= 0 and 0 <= beat["beat_phase"] < 1
            and 0 <= beat["bar_phase"] < 1 and beat["beat_in_bar"] < MAX_BPB)
        if (not finite(m) or m < self.last_pushed or not all(finite(v) for v in values)
                or not all(finite(v) for v in spectrum) or bad_beat):
            return "invalid"
        if len(self.queue) == self.c["capacity"]:
            return "full"
        self.queue.append([m, list(values), list(spectrum), beat, False])
        self.last_pushed = m
        return "ok"

    def set_clock(self, clock):
        if clock is not None:
            ok = (all(finite(clock[k]) for k in ("media_time_ms", "tempo_bpm", "beat_phase",
                                                 "bar_phase"))
                  and clock["tempo_bpm"] > 0 and 0 <= clock["beat_phase"] < 1
                  and 0 <= clock["bar_phase"] < 1 and 1 <= clock["beats_per_bar"] <= MAX_BPB
                  and clock["reserved"] == 0)
            if not ok:
                return "invalid"
        self.clock = clock
        return "ok"

    @staticmethod
    def level(peak, t, release):
        value, _, start = peak
        if start is not None and t > start:
            return value * math.exp(-(t - start) / release)
        return value

    def transient(self, hop, t):
        for k, slot in enumerate(TRANSIENTS):
            v = hop[1][slot]
            if v >= self.level(self.peaks[k], t, self.releases()[k]):
                self.peaks[k] = [v, hop[0], None]
        hop[4] = True

    def accept(self, hop):
        m, values, _, beat, _ = hop
        event = m - self.c["analysis_latency_ms"]
        if beat is not None:
            if beat["tempo_bpm"] > 0:
                fallback = self.tracker.bpb if self.tracker else 4
                bpb = None
                if beat["bar_phase"] > 0:
                    n = math.floor((beat["beat_in_bar"] + beat["beat_phase"]) / beat["bar_phase"]
                                   + 0.5)
                    if 1 <= n <= MAX_BPB and beat["beat_in_bar"] < n:
                        bpb = n
                if bpb is None:
                    bpb = max(fallback, beat["beat_in_bar"] + 1)
                if self.tracker and abs(beat["tempo_bpm"] - self.tracker.tempo) > \
                        0.06 * self.tracker.tempo:
                    self.lock_offset = 0.0
                self.tracker = Ref(event, beat["tempo_bpm"], beat["beat_phase"],
                                   beat["beat_in_bar"] + beat["beat_phase"], bpb,
                                   beat["confidence"], beat["confidence"] > 0)
            else:
                self.tracker = None
                self.lock_offset = 0.0
        onset = values[ONSET]
        r, gain = self.tracker, self.c["phase_lock_gain"]
        if r and gain > 0 and r.active and onset >= 0.5 and self.previous_onset < 0.5:
            err = wrap(r.beats_at(event) + self.lock_offset)
            if abs(err) < 0.15:
                self.lock_offset = wrap(self.lock_offset - gain * err)
        self.previous_onset = onset
        self.current = hop

    def reference(self):
        c = self.clock
        if c is not None:
            bpb = c["beats_per_bar"]
            return Ref(c["media_time_ms"], c["tempo_bpm"], c["beat_index"] + c["beat_phase"],
                       c["bar_phase"] * bpb, bpb, 1.0, True)
        r = self.tracker
        if r is None:
            return None
        return Ref(r.origin, r.tempo, r.beats + self.lock_offset, r.bar_beats + self.lock_offset,
                   r.bpb, r.confidence, r.active)

    def sample(self, time):
        if not finite(time):
            return None
        c = self.c
        t = time + c["render_ahead_ms"] + c["display_latency_ms"] - c["output_latency_ms"]
        for hop in self.queue:
            if hop[4]:
                continue
            if hop[0] - c["onset_latency_ms"] > t:
                break
            self.transient(hop, t)
        while self.queue and self.queue[0][0] - c["analysis_latency_ms"] <= t:
            hop = self.queue.pop(0)
            if not hop[4]:
                self.transient(hop, t)
            self.accept(hop)
        values, spectrum = [0.0] * 9, [0.0] * BINS
        a = self.current
        if a is not None:
            b = self.queue[0] if self.queue else None
            if b is not None and b[0] > a[0]:
                w = (t - (a[0] - c["analysis_latency_ms"])) / (b[0] - a[0])
                w = min(max(w, 0.0), 1.0)
                for s in CONTINUOUS:
                    values[s] = a[1][s] + (b[1][s] - a[1][s]) * w
                spectrum = [f32(x + (y - x) * w) for x, y in zip(a[2], b[2])]
            else:
                for s in CONTINUOUS:
                    values[s] = a[1][s]
                spectrum = list(a[2])
        for k, slot in enumerate(TRANSIENTS):
            peak = self.peaks[k]
            if peak[2] is None and t >= peak[1]:
                peak[2] = t
            values[slot] = self.level(peak, t, self.releases()[k])
        out = {"values": values, "spectrum": spectrum, "beat": 0.0, "downbeat": 0.0,
               "beat_phase": 0.0, "bar_phase": 0.0, "tempo_bpm": 0.0, "confidence": 0.0,
               "beat_count": 0, "beat_in_bar": 0, "locked": 0}
        self.sample_beat(t, out)
        return out

    def sample_beat(self, t, out):
        r = self.reference()
        if r is None:
            self.resync = True
            return
        absolute = self.clock is not None
        bpb = r.bpb

        def bar_index(bar_beats, phase):
            n = math.floor(bar_beats - phase + 0.5)
            n = n - math.floor(n / bpb) * bpb
            return min(int(n), bpb - 1)

        f = self.follower
        resync = f is None or self.resync or t < f[0] or t - f[0] > 500.0
        self.resync = False
        if resync:
            target = r.beats_at(t)
            beats = target if absolute else (math.floor(f[1]) if f else 0) + frac(target)
            f = [t, beats, bar_index(r.bar_at(t), frac(beats)), False, False, r.per_ms(), 0.0]
        else:
            dt = t - f[0]
            f[5] += (r.per_ms() - f[5]) * (1.0 - math.exp(-dt / 1000.0))
            err = wrap(r.beats_at(t) - (f[1] + dt * f[5]))
            target = min(max(err / (500.0 * f[5]), -0.15), 0.15)
            f[6] += (target - f[6]) * (1.0 - math.exp(-dt / 250.0))
            advance = dt * f[5] * (1.0 + f[6])
            residual = wrap(r.beats_at(t) - (f[1] + advance))
            if abs(residual) < 1e-9:
                advance += residual
            before = math.floor(f[1])
            f[1] += advance
            if math.floor(f[1]) > before:
                f[2] = bar_index(r.bar_at(t), frac(f[1]))
                f[3] = r.active
                f[4] = r.active and f[2] == 0
            f[0] = t
        f[2] %= bpb
        self.follower = f
        phase = frac(f[1])
        per_ms = f[5]
        decay = math.exp(-(phase / per_ms) / self.c["pulse_decay_ms"])
        x = ((1.0 - phase) / per_ms) / self.c["pulse_rise_ms"]
        rise = math.exp(-(x * x))
        next_down = (f[2] + 1) % bpb == 0
        out["beat"] = max(decay if f[3] else 0.0, rise if r.active else 0.0)
        out["downbeat"] = max(decay if f[4] else 0.0, rise if r.active and next_down else 0.0)
        out["beat_phase"] = phase
        out["bar_phase"] = (f[2] + phase) / bpb
        out["tempo_bpm"] = r.tempo
        out["confidence"] = r.confidence
        out["beat_count"] = (math.floor(r.beats_at(t) - phase + 0.5) if absolute
                             else math.floor(f[1]))
        out["beat_in_bar"] = f[2]
        out["locked"] = 1


# Scenario building ---------------------------------------------------------------------------

def num(x):
    """JSON-safe float: non-finite values as the strings the README names."""
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    return x


def r6(x):
    return round(x, 6)


class Scenario:
    def __init__(self, name, spectra=False, **config):
        self.config = dict(default_config(), **config)
        assert valid_config(self.config), name
        self.name, self.spectra = name, spectra
        self.model = Model(self.config)
        self.steps = []

    def push(self, m, values, spectrum=None, beat=None):
        spectrum = spectrum if spectrum is not None else [0.0] * BINS
        result = self.model.push(m, values, spectrum, beat)
        step = {"op": "push", "t": num(m), "values": [num(v) for v in values]}
        if any(v != 0 for v in spectrum):
            step["spectrum"] = [num(v) for v in spectrum]
        if beat is not None:
            step["beat"] = {k: num(v) if isinstance(v, float) else v for k, v in beat.items()}
        step["expect"] = result
        self.steps.append(step)
        return result

    def clock(self, clock):
        result = self.model.set_clock(clock)
        step = {"op": "clock", "clock": None if clock is None else
                {k: num(v) if isinstance(v, float) else v for k, v in clock.items()},
                "expect": result}
        self.steps.append(step)
        return result

    def reset(self):
        self.model.reset()
        self.steps.append({"op": "reset"})

    def sample(self, t):
        out = self.model.sample(t)
        if out is None:
            self.steps.append({"op": "sample", "t": num(t), "expect": "invalid"})
            return None
        expect = {k: v for k, v in out.items() if k != "spectrum"}
        expect["queued"] = len(self.model.queue)
        if self.spectra:
            expect["spectrum"] = out["spectrum"]
        self.steps.append({"op": "sample", "t": t, "expect": expect})
        return out

    def json(self):
        return {"name": self.name, "config": self.config, "steps": self.steps}


def tracked_hop(m, analysis, tempo, first_beat, beats_per_bar=4, confidence=0.8, skew=0.0,
                clicks=True, smooth=0.0, second=0.35):
    """Mapped values and tracker output of a hop ending at m on a click train at `tempo`."""
    period = 60000.0 / tempo
    event = m - analysis
    beats = (event - first_beat) / period + skew
    since = (m - first_beat) - math.floor((m - first_beat) / period) * period
    values = [0.0] * 9
    values[AMPLITUDE] = r6(0.5 + 0.3 * math.sin(m / 97.0 + smooth))
    values[LEVEL] = r6(0.4 + 0.2 * math.cos(m / 131.0))
    values[BASS] = r6(0.3 + 0.25 * math.sin(m / 53.0))
    values[MID] = r6(0.2 + 0.1 * math.sin(m / 71.0))
    values[TREBLE] = r6(0.1 + 0.05 * math.cos(m / 37.0))
    values[CENTROID] = r6(0.45 + 0.1 * math.sin(m / 211.0))
    if clicks and m >= first_beat:
        hop = math.floor(since / HOP_MS)
        values[ONSET] = (0.9, second)[hop] if hop < 2 else 0.0
        values[BASS_IMPACT] = (0.7, 0.4)[hop] if hop < 2 else 0.0
        values[FLUX] = (0.6, 0.2)[hop] if hop < 2 else 0.0
    if beats < 0:
        beat = {"tempo_bpm": 0.0, "beat_phase": 0.0, "bar_phase": 0.0, "confidence": 0.0,
                "beat_in_bar": 0}
    else:
        index = math.floor(beats)
        in_bar = index % beats_per_bar
        phase = r6(frac(beats))
        if phase >= 1.0:
            phase = 0.0
        bar_phase = min(r6((in_bar + phase) / beats_per_bar), 0.999999)
        beat = {"tempo_bpm": tempo, "beat_phase": phase, "bar_phase": bar_phase,
                "confidence": confidence,
                "beat_in_bar": in_bar}
    return values, beat


def drive(s, frames, frame_ms, start, hop_start, hop_end, hop_fn, lookahead=40.0):
    """Push hops ending in [hop_start, hop_end] as a host would (up to `lookahead` ahead of each
    sample) and sample `frames` frames from `start`."""
    k = 0
    m = hop_start
    for i in range(frames):
        t = start + i * frame_ms
        while m <= hop_end and m <= t + lookahead:
            values, beat = hop_fn(m)
            assert s.push(m, values, beat=beat) == "ok"
            k += 1
            m = hop_start + k * HOP_MS
        s.sample(t)
    return m


def tracked(name, frame_hz, seconds, tempo, skew=0.0, beats_per_bar=4, **config):
    s = Scenario(name, **config)
    lag = s.config["analysis_latency_ms"]
    drive(s, int(seconds * frame_hz), 1000.0 / frame_hz, 3.1, 2048 / 48, seconds * 1000 + 50,
          lambda m: tracked_hop(m, lag, tempo, 250.0, beats_per_bar, skew=skew))
    return s


def host_clock():
    s = Scenario("host-clock")
    lag = s.config["analysis_latency_ms"]
    fn = lambda m: tracked_hop(m, lag, 100.0, 300.0)
    s.clock({"media_time_ms": 0.0, "tempo_bpm": 0.0, "beat_phase": 0.0, "bar_phase": 0.0,
             "beat_index": 0, "beats_per_bar": 4, "reserved": 0})
    s.clock({"media_time_ms": math.nan, "tempo_bpm": 120.0, "beat_phase": 0.0,
             "bar_phase": 0.0, "beat_index": 0, "beats_per_bar": 4, "reserved": 0})
    s.clock({"media_time_ms": 0.0, "tempo_bpm": 120.0, "beat_phase": 1.0, "bar_phase": 0.0,
             "beat_index": 0, "beats_per_bar": 4, "reserved": 0})
    s.clock({"media_time_ms": 0.0, "tempo_bpm": 120.0, "beat_phase": 0.0, "bar_phase": 0.0,
             "beat_index": 0, "beats_per_bar": 17, "reserved": 0})
    s.clock({"media_time_ms": 0.0, "tempo_bpm": 120.0, "beat_phase": 0.0, "bar_phase": 0.0,
             "beat_index": 0, "beats_per_bar": 4, "reserved": 1})
    m = drive(s, 20, 1000 / 60, 3.1, 2048 / 48, 2000.0, fn)
    s.clock({"media_time_ms": 400.0, "tempo_bpm": 128.0, "beat_phase": 0.25,
             "bar_phase": 0.75, "beat_index": 41, "beats_per_bar": 3, "reserved": 0})
    t0 = 3.1 + 20 * 1000 / 60
    m = drive(s, 40, 1000 / 60, t0, m, 2400.0, fn)
    # A replacement clock half a beat away: the output slews, it does not jump.
    s.clock({"media_time_ms": 1500.0, "tempo_bpm": 128.0, "beat_phase": 0.5,
             "bar_phase": 0.75, "beat_index": -3, "beats_per_bar": 6, "reserved": 0})
    t0 += 40 * 1000 / 60
    m = drive(s, 6, 1000 / 60, t0, m, 2900.0, fn)
    # 0.35 beats ahead: the output speeds up by at most PHASE_CORRECTION of its rate.
    s.clock({"media_time_ms": 1500.0, "tempo_bpm": 128.0, "beat_phase": 0.85,
             "bar_phase": 0.808333, "beat_index": -3, "beats_per_bar": 6, "reserved": 0})
    t0 += 6 * 1000 / 60
    m = drive(s, 15, 1000 / 60, t0, m, 2900.0, fn)
    # Back to the tracker's four beats from beat 5 of 6: the bar index wraps into the new bar.
    s.clock(None)
    t0 += 15 * 1000 / 60
    drive(s, 20, 1000 / 60, t0, m, 3400.0, fn)
    return s


def seek_and_reset():
    s = Scenario("seek-and-reset", output_latency_ms=12.5)
    lag = s.config["analysis_latency_ms"]
    fn = lambda m: tracked_hop(m, lag, 132.0, 120.0)
    m = drive(s, 30, 1000 / 60, 10.0, 2048 / 48, 700.0, fn)
    for t in (300.0, 312.0, 328.0, 1100.0, 1116.6, 1133.3, 1133.3):
        s.sample(t)  # back (resync), forward 772 ms (resync), then repeated time (dt 0)
    s.sample(math.nan)
    s.sample(math.inf)
    s.reset()
    s.sample(20.0)
    # The media timeline restarts after a reset: earlier times are accepted again.
    drive(s, 30, 1000 / 60, 500.0, 400.0, 1100.0, fn)
    return s


def tempo_changes():
    s = Scenario("tempo-changes", phase_lock_gain=0.25)
    lag = s.config["analysis_latency_ms"]

    def fn(m):
        if m < 1200:   # 90 BPM in 3/4, tracker phase 0.06 beats late: the lock pulls it in
            # The second hop of each click stays above the lock onset: only the first locks.
            return tracked_hop(m, lag, 90.0, 200.0, 3, skew=-0.06, second=0.6)
        if m < 2200:   # 140 BPM: more than 6%, the learned offset is dropped
            return tracked_hop(m, lag, 140.0, 1210.0 - 3 * 60000 / 140, 4, skew=0.04)
        if m < 2600:   # tempo 0: no tracker, no beat outputs
            values, _ = tracked_hop(m, lag, 140.0, 1210.0 - 3 * 60000 / 140)
            return values, {"tempo_bpm": 0.0, "beat_phase": 0.0, "bar_phase": 0.0,
                            "confidence": 0.0, "beat_in_bar": 0}
        if m < 2900:   # 100 BPM without a bar phase: bar length falls back
            values, beat = tracked_hop(m, lag, 100.0, 2620.0, 5, confidence=0.5)
            return values, dict(beat, bar_phase=0.0)
        if m < 3100:   # hops without tracker output keep the reference
            values, _ = tracked_hop(m, lag, 100.0, 2620.0)
            return values, None
        values, beat = tracked_hop(m, lag, 100.0, 2620.0, 5, confidence=0.0)
        return values, beat  # confidence 0: phases run, no pulse

    drive(s, 200, 1000 / 60, 3.1, 2048 / 48, 3350.0, fn)
    return s


def early_onsets():
    """onset latency below analysis latency, spectra, equal hop times."""
    s = Scenario("early-onsets-and-spectra", spectra=True, onset_latency_ms=0.0,
                 analysis_latency_ms=20.0, render_ahead_ms=8.0)
    for i in range(14):
        m = 30.0 + i * HOP_MS
        if i == 6:
            m = 30.0 + 5 * HOP_MS  # same time as the previous hop: values hold
        values = [r6(0.1 * (i % 5)), 0.2, 0.3, 0.1, 0.05, (0.8 if i in (3, 9) else 0.1),
                  (0.6 if i == 3 else 0.0), 0.25 * (i % 2), r6(0.3 + 0.01 * i)]
        spectrum = [f32((b + 1) / 64.0 * (1 + (i % 3)) / 3.0) for b in range(BINS)]
        assert s.push(m, values, spectrum) == "ok"
        s.sample(10.0 + i * 9.0)
    for i in range(14, 24):
        s.sample(10.0 + i * 9.0)
    return s


def refusals():
    s = Scenario("refusals", capacity=3)
    good = [0.1] * 9
    beat = {"tempo_bpm": 120.0, "beat_phase": 0.5, "bar_phase": 0.125, "confidence": 1.0,
            "beat_in_bar": 0}
    s.push(math.nan, good)
    s.push(math.inf, good)
    s.push(50.0, good, beat=beat)
    s.push(49.0, good)                                      # earlier than the last
    s.push(60.0, good[:4] + [math.nan] + good[5:])
    spectrum = [0.0] * BINS
    spectrum[7] = math.inf
    s.push(60.0, good, spectrum)
    s.push(60.0, good, beat=dict(beat, beat_phase=1.0))
    s.push(60.0, good, beat=dict(beat, bar_phase=-0.25))
    s.push(60.0, good, beat=dict(beat, tempo_bpm=-1.0))
    s.push(60.0, good, beat=dict(beat, confidence=math.nan))
    s.push(60.0, good, beat=dict(beat, beat_in_bar=16))
    s.push(60.0, good, beat=dict(beat, beat_in_bar=15, bar_phase=0.0))  # bar length 16
    s.push(60.0, good)                                      # equal time is accepted
    s.push(61.0, good)                                      # full
    s.sample(math.nan)
    s.sample(100.0)
    s.push(61.0, good)
    s.push(62.0, good)
    s.push(63.0, good)
    s.push(64.0, good)                                      # full again
    s.sample(-math.inf)
    s.sample(120.0)
    return s


def config_cases():
    base = default_config()
    cases = [("default", {})]
    for key, values in (("struct_size", [104, 0]), ("capacity", [0, MAX_CAPACITY + 1,
                                                                   MAX_CAPACITY, 1]),
                        ("output_latency_ms", [-0.001, math.inf, 0.0]),
                        ("display_latency_ms", [-1.0, math.nan]),
                        ("render_ahead_ms", [-1.0, 100.0]),
                        ("analysis_latency_ms", [-1.0, math.inf]),
                        ("onset_latency_ms", [-1.0, 0.0]),
                        ("onset_release_ms", [0.0, -1.0, math.inf]),
                        ("bass_impact_release_ms", [0.0]), ("flux_release_ms", [math.nan]),
                        ("pulse_decay_ms", [0.0]), ("pulse_rise_ms", [-0.5]),
                        ("phase_lock_gain", [-0.01, 1.01, math.nan, 0.0, 1.0])):
        for v in values:
            cases.append((f"{key}={num(v)}", {key: v}))
    out = []
    for name, change in cases:
        config = dict(base, **change)
        out.append({"name": name, "config": {k: num(v) for k, v in config.items()},
                    "valid": valid_config(config)})
    return out


def dsp_rows():
    rows = []
    for version in (0, 1, 2, 3, 4, 5):
        for rate in (0, 44100, 48000, 96000):
            row = for_dsp(version, rate)
            rows.append({"behavior_version": version, "sample_rate_hz": rate,
                         "latency": None if row is None else
                         {"analysis_latency_ms": row[0], "onset_latency_ms": row[1]}})
    return rows


def build():
    scenarios = [
        tracked("tracked-60hz", 60, 1.6, 120.0),
        tracked("tracked-30hz-latencies", 30, 2.0, 150.0, skew=0.03, output_latency_ms=25.3,
                display_latency_ms=11.0, render_ahead_ms=33.333),
        tracked("tracked-120hz-v1-44k", 120, 1.0, 185.0, skew=-0.05, phase_lock_gain=0.2,
                output_latency_ms=4.0, display_latency_ms=8.333,
                analysis_latency_ms=for_dsp(1, 44100)[0], onset_latency_ms=for_dsp(1, 44100)[1]),
        tracked("tracked-60hz-no-lock-7-8", 60, 1.2, 172.0, skew=0.08, beats_per_bar=7,
                phase_lock_gain=0.0, capacity=4096),
        host_clock(),
        seek_and_reset(),
        tempo_changes(),
        early_onsets(),
        refusals(),
    ]
    return {
        "spec": "conformance/reaction/README.md",
        "generator": "tools/reaction-vectors.py",
        "tolerance": TOLERANCE,
        "for_dsp": dsp_rows(),
        "configs": config_cases(),
        "scenarios": [s.json() for s in scenarios],
    }


def render(doc):
    """One step per line, so a change shows as a readable diff."""
    lines = ["{"]
    keys = list(doc)
    for i, key in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        value = doc[key]
        if isinstance(value, list):
            lines.append(f"  {json.dumps(key)}: [")
            for j, item in enumerate(value):
                end = "," if j < len(value) - 1 else ""
                if isinstance(item, dict) and "steps" in item:
                    head = {k: v for k, v in item.items() if k != "steps"}
                    text = json.dumps(head, separators=(",", ":"), allow_nan=False)[:-1]
                    lines.append(f"    {text},\"steps\":[")
                    for n, step in enumerate(item["steps"]):
                        sep = "," if n < len(item["steps"]) - 1 else ""
                        lines.append("      " + json.dumps(step, separators=(",", ":"),
                                                           allow_nan=False) + sep)
                    lines.append(f"    ]}}{end}")
                else:
                    lines.append("    " + json.dumps(item, separators=(",", ":"),
                                                     allow_nan=False) + end)
            lines.append(f"  ]{comma}")
        else:
            lines.append(f"  {json.dumps(key)}: {json.dumps(value)}{comma}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def summary(doc):
    samples = sum(1 for s in doc["scenarios"] for st in s["steps"] if st["op"] == "sample")
    steps = sum(len(s["steps"]) for s in doc["scenarios"])
    return (f"{len(doc['scenarios'])} scenarios, {steps} steps, {samples} samples, "
            f"{len(doc['configs'])} config cases, {len(doc['for_dsp'])} for_dsp rows")


def main():
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__)
    doc = build()
    text = render(doc)
    json.loads(text)
    if check:
        try:
            with open(VECTORS, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            current = None
        if current != text:
            print("reaction-vectors: conformance/reaction/vectors.json differs from the model; "
                  "run python3 -I tools/reaction-vectors.py", file=sys.stderr)
            sys.exit(1)
        print(f"reaction-vectors: vectors.json matches the model ({summary(doc)})")
        return
    os.makedirs(os.path.dirname(VECTORS), exist_ok=True)
    with open(VECTORS, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"reaction-vectors: wrote conformance/reaction/vectors.json ({summary(doc)})")


if __name__ == "__main__":
    main()
