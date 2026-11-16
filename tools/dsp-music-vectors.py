#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the synthetic music scores under conformance/dsp/music/scores/.

Each score is a list of synthesis events (tones and filtered noise) with exact onset, beat and
downbeat annotations, as conformance/dsp/music/README.md specifies. The renderer uses only
addition, subtraction, multiplication, division, floor and comparisons on IEEE doubles, so the
Rust renderer in crates/oscillux-core/tests/dsp_music.rs reproduces the 16-bit samples exactly;
each score records an FNV-1a digest of the samples this script renders. The WAVs are rendered
at test time and not committed.

Usage: python3 tools/dsp-music-vectors.py
       python3 tools/dsp-music-vectors.py --check   (exit 1 if a generated file differs)

--check writes into a temporary directory and compares it with the committed output file by
file, so a missing, extra or changed file fails.
"""

import filecmp
import itertools
import math
import operator
import os
import sys
import tempfile
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MUSIC_DIR = os.path.join(ROOT, "conformance", "dsp", "music")
OUT_DIRS = {"scores": os.path.join(MUSIC_DIR, "scores")}

RATE = 48000
GAIN = 0.45
NOISE_TABLE_SIZE = 1 << 16
NOISE_SEED = 20261020
ONSET_MERGE_SAMPLES = 1200  # 25 ms: annotated onsets closer than this are one onset
LEAD_IN_SECONDS = 0.5
TAIL_SECONDS = 1.0


# --- Synthesis ---------------------------------------------------------------------------------

def noise_table():
    """65536 uniform values in [-0.5, 0.5) from the 64-bit LCG of tools/dsp-v2-vectors.py."""
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


def tone(length, f_start, f_end, glide):
    """Frequency f_end + (f_start - f_end) g_i with g_0 = 1, g_(i+1) = g_i * glide; phase
    P_0 = 0, P_(i+1) = P_i + f_i * (1 / RATE)."""
    glides = itertools.accumulate(itertools.repeat(glide, length - 1), operator.mul, initial=1.0)
    span, step = f_start - f_end, 1.0 / RATE
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
    """16-bit samples of a score: events summed in file order, scaled by the gain, quantised."""
    buf = [0.0] * score["samples"]
    for event in score["events"]:
        kind, start, length, attack, release, amp, decay = event[:7]
        env = envelope(length, attack, release, amp, decay)
        if kind == "tone":
            shape = tone(length, *event[7:10])
        else:
            shape = noise(length, *event[7:9])
        for i, (e, s) in enumerate(zip(env, shape)):
            buf[start + i] += e * s
    gain = score["gain"]
    return [quantise(gain * x) for x in buf]


def fnv1a(pcm):
    """FNV-1a over the little-endian bytes of the 16-bit samples."""
    h = 0xcbf29ce484222325
    for byte in b"".join(int.to_bytes(s & 0xFFFF, 2, "little") for s in pcm):
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


# --- Instruments and arrangements --------------------------------------------------------------

def per_sample(tau_seconds):
    """Per-sample factor of an exponential with time constant tau."""
    return math.exp(-1.0 / (tau_seconds * RATE))


def samples(seconds):
    return int(math.floor(seconds * RATE + 0.5))


class Score:
    def __init__(self, name, description, seed=2):
        self.name, self.description = name, description
        self.events, self.onsets, self.beats = [], [], []
        self.seed = seed

    def add(self, *event):
        self.events.append(event)

    def next_seed(self, length):
        seed = self.seed
        self.seed = (self.seed + length + 7919) & (NOISE_TABLE_SIZE - 1)
        return seed

    def kick(self, at, accent=1.0):
        self.add("tone", at, samples(0.3), 24, 480, 0.85 * accent, per_sample(0.07),
                 160.0, 48.0, per_sample(0.025))
        self.onsets.append(at)

    def snare(self, at, level=1.0):
        self.add("tone", at, samples(0.18), 24, 480, 0.3 * level, per_sample(0.04),
                 220.0, 180.0, per_sample(0.01))
        length = samples(0.2)
        self.add("noise", at, length, 24, 480, 0.6 * level, per_sample(0.06),
                 self.next_seed(length), 1)
        self.onsets.append(at)

    def hat(self, at, open_hat=False, level=1.0):
        length = samples(0.25 if open_hat else 0.05)
        tau = 0.08 if open_hat else 0.012
        self.add("noise", at, length, 12, 240, 0.3 * level, per_sample(tau),
                 self.next_seed(length), 2)
        self.onsets.append(at)

    def bass(self, at, seconds, hz, level=1.0):
        self.add("tone", at, samples(seconds), 240, 1440, 0.35 * level, per_sample(0.5),
                 hz, hz, 1.0)
        self.onsets.append(at)

    def crash(self, at):
        length = samples(1.2)
        self.add("noise", at, length, 0, 4800, 0.35, per_sample(0.4), self.next_seed(length), 1)
        self.onsets.append(at)

    def pad(self, at, seconds, chord, level=1.0):
        """Slow-attack chord: no annotated onset."""
        for hz in chord:
            self.add("tone", at, samples(seconds), RATE, RATE, 0.08 * level, 1.0, hz, hz, 1.0)

    def noise_bed(self, at, seconds, level):
        """Steady noise with half-second fades: no annotated onset."""
        length = samples(seconds)
        self.add("noise", at, length, RATE // 2, RATE // 2, level, 1.0, self.next_seed(length), 0)

    def finish(self):
        last = max(start + length for _, start, length, *_ in self.events)
        total = max(last, self.beats[-1][0]) + samples(TAIL_SECONDS)
        merged = []
        for at in sorted(self.onsets):
            if not merged or at - merged[-1] >= ONSET_MERGE_SAMPLES:
                merged.append(at)
        return {"name": self.name, "description": self.description, "samples": total,
                "gain": GAIN, "events": self.events, "onsets": merged, "beats": self.beats}


ROOTS = (55.0, 73.42, 61.74, 82.41)  # A1, D2, B1, E2: one root per bar, cycling


def beat_grid(tempi):
    """Beat start samples for a list of per-beat tempi in BPM, from the lead-in."""
    t, out = LEAD_IN_SECONDS, []
    for bpm in tempi:
        out.append((t, 60.0 / bpm))
        t += 60.0 / bpm
    return out


def straight_bar(score, beats, bar, crash_every=4):
    """Kick on 1 and 3, snare on 2 and 4, eighth hats, bass on 1 and the off-beat of 2."""
    root = ROOTS[bar % len(ROOTS)]
    for slot, (t, period) in enumerate(beats):
        at = samples(t)
        score.beats.append((at, slot == 0))
        if slot in (0, 2):
            score.kick(at, 1.0 if slot == 0 else 0.8)
        else:
            score.snare(at)
        if slot == 0 and bar % crash_every == 0:
            score.crash(at)
        score.hat(at, level=0.8)
        score.hat(samples(t + period / 2), level=0.6)
        if slot == 0:
            score.bass(at, period * 1.4, root)
        if slot == 1:
            score.bass(samples(t + period / 2), period * 0.9, root * 1.5)


def music_tempo_steps():
    s = Score("music-tempo-steps", "straight rock pattern; 16 beats at 96 BPM, 24 at 128 BPM, "
              "20 at 108 BPM; crash on the first bar of each tempo and every fourth bar")
    grid = beat_grid([96.0] * 16 + [128.0] * 24 + [108.0] * 20)
    bars = [grid[i:i + 4] for i in range(0, len(grid), 4)]
    for bar, beats in enumerate(bars):
        straight_bar(s, beats, bar, crash_every=4)
        if bar in (4, 10):
            s.crash(samples(beats[0][0]))
    return s.finish()


def music_syncopated_swing():
    s = Score("music-syncopated-swing", "112 BPM, 64 beats; swung eighth hats (2:1), kick on 1, "
              "the swung off-beat of 2 and beat 3 in alternate bars, snare on 2 and 4, ghost "
              "snares on the swung off-beat of 3, syncopated bass, open hat every other bar")
    grid = beat_grid([112.0] * 64)
    for bar in range(16):
        beats = grid[bar * 4:bar * 4 + 4]
        root = ROOTS[bar % len(ROOTS)]
        swing = lambda slot: beats[slot][0] + beats[slot][1] * 2.0 / 3.0
        for slot, (t, period) in enumerate(beats):
            at = samples(t)
            s.beats.append((at, slot == 0))
            s.hat(at, level=0.8)
            if not (slot == 3 and bar % 2 == 1):
                s.hat(samples(swing(slot)), level=0.5)
            if slot in (1, 3):
                s.snare(at)
        s.kick(samples(beats[0][0]), 1.0)
        s.kick(samples(swing(1)), 0.8)
        if bar % 2 == 0:
            s.kick(samples(beats[2][0]), 0.8)
        s.snare(samples(swing(2)), level=0.3)
        if bar % 2 == 1:
            s.hat(samples(swing(3)), open_hat=True, level=0.8)
        if bar % 4 == 0:
            s.crash(samples(beats[0][0]))
        period = beats[0][1]
        s.bass(samples(beats[0][0]), period * 0.6, root)
        s.bass(samples(swing(1)), period * 0.9, root)
        s.bass(samples(swing(2)), period * 0.9, root * 1.5)
    return s.finish()


def music_pad_noise():
    s = Score("music-pad-noise", "90 BPM, 52 beats: 24 beats of drums over a quiet noise bed, "
              "12 beats of a slow-attack pad alone (beats annotated, no onsets), 16 beats of "
              "drums, pad and a louder noise bed")
    grid = beat_grid([90.0] * 52)
    start = lambda beat: grid[beat][0]
    end = grid[-1][0] + grid[-1][1]
    s.noise_bed(samples(start(0)), start(24) - start(0), 0.03)
    s.pad(samples(start(24) - 1.0), end - start(24) + 1.0, (220.0, 277.18, 329.63))
    s.noise_bed(samples(start(36)), end - start(36), 0.08)
    for bar in range(13):
        beats = grid[bar * 4:bar * 4 + 4]
        if 6 <= bar < 9:
            for slot, (t, _) in enumerate(beats):
                s.beats.append((samples(t), slot == 0))
            continue
        straight_bar(s, beats, bar, crash_every=4 if bar < 6 else 3)
    return s.finish()


def music_ramp():
    s = Score("music-ramp", "four-on-the-floor kick, off-beat open hats, snare on 2 and 4, bass "
              "on the off-beats; tempo ramps linearly per beat from 100 to 136 BPM over 64 beats")
    grid = beat_grid([100.0 + 36.0 * k / 63.0 for k in range(64)])
    for bar in range(16):
        beats = grid[bar * 4:bar * 4 + 4]
        root = ROOTS[bar % len(ROOTS)]
        for slot, (t, period) in enumerate(beats):
            at = samples(t)
            s.beats.append((at, slot == 0))
            s.kick(at, 1.0 if slot == 0 else 0.75)
            if slot in (1, 3):
                s.snare(at, level=0.8)
            off = samples(t + period / 2)
            s.hat(off, open_hat=True, level=0.6)
            s.bass(off, period * 0.45, root * (1.5 if slot == 3 else 1.0))
        if bar % 4 == 0:
            s.crash(samples(beats[0][0]))
    return s.finish()


def music_heldout_breakbeat():
    """Held out: added after every parameter of the onset picker, beat tracker and normaliser
    was fixed, and never used to choose one. Its results are reported, not asserted."""
    s = Score("music-heldout-breakbeat", "held out, never tuned on: 142 BPM breakbeat, 64 beats; "
              "kick on 1, the off-beat of 2 and the last sixteenth of 3, snare on 2 and 4 with a "
              "ghost on the last sixteenth of 4, sixteenth hats, bass on the kicks, open hat "
              "every other bar, a sixteenth snare fill over beats 3-4 of every eighth bar, "
              "crash every eight bars; noise seed 30011", seed=30011)
    roots = (41.2, 49.0, 55.0, 65.41)  # E1, G1, A1, C2
    grid = beat_grid([142.0] * 64)
    for bar in range(16):
        beats = grid[bar * 4:bar * 4 + 4]
        root = roots[bar % len(roots)]
        fill = bar % 8 == 7
        sixteenth = lambda slot, n: samples(beats[slot][0] + beats[slot][1] * n / 4.0)
        for slot, (t, period) in enumerate(beats):
            s.beats.append((samples(t), slot == 0))
            if fill and slot >= 2:
                for n in range(4):
                    s.snare(sixteenth(slot, n), level=0.4 + 0.15 * n)
                continue
            for n, level in enumerate((0.7, 0.35, 0.5, 0.35)):
                s.hat(sixteenth(slot, n), level=level)
            if slot in (1, 3):
                s.snare(sixteenth(slot, 0))
        kicks = [(0, 0, 1.0), (1, 2, 0.8)]
        if not fill:
            kicks.append((2, 3, 0.85))
        for slot, n, accent in kicks:
            s.kick(sixteenth(slot, n), accent)
            s.bass(sixteenth(slot, n), beats[slot][1] * 0.7, root)
        if not fill:
            s.snare(sixteenth(3, 3), level=0.35)
        if bar % 2 == 1 and not fill:
            s.hat(sixteenth(3, 2), open_hat=True, level=0.7)
        if bar % 8 == 0:
            s.crash(sixteenth(0, 0))
    return s.finish()


SCORES = (music_tempo_steps, music_syncopated_swing, music_pad_noise, music_ramp,
          music_heldout_breakbeat)


# --- Output ------------------------------------------------------------------------------------

def score_text(score, digest):
    lines = [
        "# dsp-music-score v1",
        "# %s: %s" % (score["name"], score["description"]),
        "# expected PCM and annotations: tools/dsp-music-vectors.py; floats are shortest "
        "round-trip decimal",
        "rate %d" % RATE,
        "samples %d" % score["samples"],
        "gain %r" % score["gain"],
        "pcm_fnv1a %016x" % digest,
        "# tone start length attack release amp decay f_start f_end glide",
        "# noise start length attack release amp decay seed highpass",
    ]
    for event in score["events"]:
        lines.append(" ".join([event[0]] + [repr(v) for v in event[1:]]))
    lines.append("# onset sample")
    lines += ["onset %d" % at for at in score["onsets"]]
    lines.append("# beat sample downbeat")
    lines += ["beat %d %d" % (at, int(down)) for at, down in score["beats"]]
    return "\n".join(lines) + "\n"


def generate(out_dirs):
    for path in out_dirs.values():
        os.makedirs(path, exist_ok=True)
    for build in SCORES:
        started = time.time()
        score = build()
        pcm = render(score)
        clipped = sum(1 for s in pcm if abs(s) == 32767)
        peak = max(abs(s) for s in pcm) / 32767.0
        with open(os.path.join(out_dirs["scores"], score["name"] + ".score"), "w") as handle:
            handle.write(score_text(score, fnv1a(pcm)))
        print("%-24s %6.2f s, %4d events, %3d onsets, %2d beats, peak %.3f, %d clipped, "
              "rendered in %.1f s" % (score["name"], score["samples"] / RATE, len(score["events"]),
                                      len(score["onsets"]), len(score["beats"]), peak, clipped,
                                      time.time() - started))


def check():
    problems = []
    with tempfile.TemporaryDirectory() as fresh:
        dirs = {key: os.path.join(fresh, key) for key in OUT_DIRS}
        generate(dirs)
        for key, committed in OUT_DIRS.items():
            wanted = sorted(os.listdir(dirs[key]))
            have = sorted(os.listdir(committed)) if os.path.isdir(committed) else []
            _, changed, unreadable = filecmp.cmpfiles(dirs[key], committed, wanted, shallow=False)
            missing = [n for n in wanted if n not in have]
            extra = [n for n in have if n not in wanted]
            found = [("changed", changed), ("missing", missing), ("not generated", extra),
                     ("unreadable", [n for n in unreadable if n not in missing])]
            problems += ["%s %s: %s" % (key, kind, ", ".join(names)) for kind, names in found
                         if names]
    if problems:
        sys.exit("conformance/dsp/music/ differs from the generator output; regenerate it\n"
                 + "\n".join(problems))
    print("conformance/dsp/music/: generated files match")


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif sys.argv[1:]:
        sys.exit("usage: python3 tools/dsp-music-vectors.py [--check]")
    else:
        generate(OUT_DIRS)


if __name__ == "__main__":
    main()
