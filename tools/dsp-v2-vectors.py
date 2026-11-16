#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the DSP behaviour version 2 vectors under conformance/dsp/v2/.

This is an independent model of "Behaviour version 2" in conformance/dsp/README.md, written from
that text in standard-library Python (no numpy). It shares no code or intermediate values with
the Rust analyzer and computes differently wherever the specification allows: a full-length
complex FFT of the real input (Rust packs it into a half-length transform), a direct sum of
squares for RMS (Rust keeps 64-sample block sums), a direct FIR convolution for the bass
decimation (Rust filters from its sample ring), and whole-segment lists instead of rings.
Expected values come from this model only. Rust output is compared against them within the
published tolerances and is never copied into them; the recorded digests are of Rust output.

Inputs are the version 1 WAVs in conformance/dsp/ (with their chunk rows) plus two signals this
script synthesises into conformance/dsp/v2/: a 6 s version of the kick signal, whose generator is
first checked byte for byte against the committed conformance/dsp/kicks-120bpm.wav, and a
full-scale 60 Hz sine. The script also prints the onset and 60 Hz acceptance measurements.

It also synthesises the edge-case fixtures of conformance/dsp/music/README.md (44.1 kHz, a
non-default configuration, stereo anti-phase, replaced non-finite samples): their WAV inputs and
`.spec` rows into conformance/dsp/music/, and their version 2 frames into conformance/dsp/music/v2/.
Their version 1 frames come from the Go reference, not from this script.

Usage: python3 tools/dsp-v2-vectors.py
       python3 tools/dsp-v2-vectors.py --check   (exit 1 if a generated file differs)

--check writes into a temporary directory and compares it with conformance/dsp/v2/ and
conformance/dsp/music/v2/ file by file, so a missing, extra or changed file fails, and compares
the generated inputs in conformance/dsp/music/ with the committed ones.
"""

import filecmp
import math
import os
import struct
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
V1_DIR = os.path.join(ROOT, "conformance", "dsp")
OUT_DIR = os.path.join(V1_DIR, "v2")
EDGE_DIR = os.path.join(V1_DIR, "music")
EDGE_V2_DIR = os.path.join(EDGE_DIR, "v2")

DEFAULT = {
    "sample_rate_hz": 48000,
    "fft_window_samples": 2048,
    "hop_samples": 512,
    "spectrum_bands": 24,
    "spectrum_min_hz": 40.0,
    "spectrum_max_hz": 16000.0,
    "db_floor": -90.0,
    "ballistics_attack_ms": 10.0,
    "ballistics_release_ms": 200.0,
    "rms_window_ms": 300.0,
    "loudness_reference_lufs": -18.0,
    "rms_floor": 1e-9,
    "onset_peak_decay": 0.995,
    "onset_peak_floor": 1e-9,
    "onset_band_groups": ((0, 7), (8, 15), (16, 23)),
    "gap_tolerance_hops": 1,
}

# Version 2 constants, as the README states them.
ONSET_FLOOR = 0.01
BASS_RATE_HZ = 6000
BASS_WINDOW = 1024
CIC_ORDER = 4
BASS_TOP_FRACTION = 0.1
BASS_MAX_MAIN_BINS = 4.0
BASS_MAX_DECIMATION = 256

FIXTURES = (
    # name, sample rate, signal source (None: the committed v1 WAV)
    ("sine-440", 48000, None),
    ("sines-low-mid-high", 48000, None),
    ("noise-white", 48000, None),
    ("kicks-120bpm", 48000, None),
    ("silence", 48000, None),
    ("sweep-40-16k", 48000, None),
    ("chunked-gap-stall", 48000, None),
    ("silence-44k1-chunked", 44100, None),
    ("kicks-120bpm-long", 48000, "kicks"),
    ("sine-60-full", 48000, "sine60"),
)
SYNTH_SIGNALS = {
    "kicks": "pitch-swept kick every 0.5 s with off-beat noise hats, 6 s (v1 kick generator)",
    "sine60": "60 Hz sine at 16-bit full scale (amplitude 32767/32768), 0.5 s",
}

# Edge-case fixtures (conformance/dsp/music/README.md). Fields: name, configuration fields that
# differ from DEFAULT, channel count, signal description, chunk rows (media_start_ms, begin, end,
# stalled; none means one chunk at 0 ms) and replaced samples (sample frame index, kind). The Go
# reference hard-codes onset_peak_decay, onset_peak_floor and rms_floor, so they stay default.
CONFIG_32K = {
    "sample_rate_hz": 32000,
    "fft_window_samples": 1024,
    "hop_samples": 256,
    "spectrum_bands": 16,
    "spectrum_min_hz": 50.0,
    "spectrum_max_hz": 12000.0,
    "db_floor": -80.0,
    "ballistics_attack_ms": 5.0,
    "ballistics_release_ms": 150.0,
    "rms_window_ms": 100.0,
    "loudness_reference_lufs": -14.0,
    "onset_band_groups": ((0, 4), (5, 10), (11, 15)),
    "gap_tolerance_hops": 2,
}
EDGE_FIXTURES = (
    ("kicks-44k1", {"sample_rate_hz": 44100}, 1,
     "kick signal at 44.1 kHz, 1.5 s, default configuration otherwise", (), ()),
    # The second chunk starts 1.5 hops after the expected time: a gap at the default tolerance of
    # one hop, but not at two. The third is 5 hops late and stalled.
    ("kicks-config-32k", CONFIG_32K, 1,
     "kick signal plus 330 Hz sine (amplitude 0.2) at 32 kHz, 1.5 s, non-default configuration, "
     "three chunks",
     ((0.0, 0, 16000, False), (516.0, 16000, 32000, False), (1060.0, 32000, 48000, True)), ()),
    ("stereo-antiphase", {}, 2,
     "stereo, 1 s: both channels carry the kick signal and a 220 Hz sine (amplitude 0.1); a "
     "1 kHz sine (amplitude 0.3) is added to the left and subtracted from the right channel", (), ()),
    # Replaced samples sit in the first window, mid-stream, as an adjacent pair, on both sides of
    # the window end 24576, and after the last window end (47616), where no frame reports them.
    ("nan-replaced", {}, 1,
     "kick signal, 1 s; the WAV holds 0 where the replace rows inject a non-finite or "
     "beyond-f32 sample", (),
     ((100, "nan"), (3000, "inf"), (10000, "-inf"), (10001, "1e39"), (24575, "nan"),
      (24576, "1e39"), (47999, "inf"))),
)


# --- Signals and WAV ---------------------------------------------------------------------------

def quantise(value):
    """Clamp to [-1, 1] and round value * 32767 half away from zero."""
    x = max(-1.0, min(1.0, value)) * 32767
    return int(math.copysign(math.floor(abs(x) + 0.5), x))


def lcg(seed):
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        yield (state >> 11) / 2.0 ** 53 - 0.5


def kick_values(seconds, rate=48000):
    """The README's kick signal before quantisation: a kick every 0.5 s and noise hats offset
    by 0.25 s."""
    noise = lcg(12345)
    values = []
    for i in range(int(seconds * rate)):
        t_abs = i / rate
        t = math.fmod(t_abs, 0.5)
        phase = 2 * math.pi * (50 * t + 100 * (1 - math.exp(-30 * t)) / 30)
        value = 0.9 * math.exp(-12 * t) * math.sin(phase)
        hat_t = math.fmod(t_abs + 0.25, 0.5)
        value += 0.25 * math.exp(-80 * hat_t) * next(noise)
        values.append(value)
    return values


def kick_pcm(seconds, rate=48000):
    return [quantise(v) for v in kick_values(seconds, rate)]


def sine_pcm(hz, seconds, rate=48000):
    return [quantise(math.sin(2 * math.pi * hz * i / rate)) for i in range(int(seconds * rate))]


def wav_bytes(pcm, rate, channels=1):
    """16-bit PCM WAV; `pcm` is interleaved when `channels` > 1."""
    data = struct.pack("<%dh" % len(pcm), *pcm)
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * 2 * channels, 2 * channels, 16)
    return (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE" + b"fmt "
            + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(data)) + data)


def read_wav(path):
    """16-bit PCM samples of a WAV file, decoded as sample / 32768 and mixed down by summing the
    channels in order from 0 and dividing by the channel count."""
    with open(path, "rb") as handle:
        raw = handle.read()
    offset, rate, pcm, channels = 12, None, None, None
    while offset + 8 <= len(raw):
        tag, size = raw[offset:offset + 4], struct.unpack("<I", raw[offset + 4:offset + 8])[0]
        body = raw[offset + 8:offset + 8 + size]
        if tag == b"fmt ":
            fmt, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            assert fmt == 1 and channels >= 1 and bits == 16, path
        elif tag == b"data":
            pcm = struct.unpack("<%dh" % (len(body) // 2), body)
        offset += 8 + size + size % 2
    if channels == 1:
        return rate, [s / 32768.0 for s in pcm]
    mixed = []
    for at in range(0, len(pcm), channels):
        total = 0.0
        for s in pcm[at:at + channels]:
            total += s / 32768.0
        mixed.append(total / channels)
    return rate, mixed


# --- Transforms --------------------------------------------------------------------------------

_TWIDDLES = {}


def complex_fft(re, im):
    """In-place iterative radix-2 DFT, X_k = sum_n x_n exp(-2 pi i k n / N)."""
    n = len(re)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            re[i], re[j] = re[j], re[i]
            im[i], im[j] = im[j], im[i]
    size = 2
    while size <= n:
        half = size // 2
        if size not in _TWIDDLES:
            _TWIDDLES[size] = [(math.cos(2 * math.pi * k / size), -math.sin(2 * math.pi * k / size))
                               for k in range(half)]
        twiddles = _TWIDDLES[size]
        for start in range(0, n, size):
            for k in range(half):
                wr, wi = twiddles[k]
                a, b = start + k, start + k + half
                tr = re[b] * wr - im[b] * wi
                ti = re[b] * wi + im[b] * wr
                re[b], im[b] = re[a] - tr, im[a] - ti
                re[a], im[a] = re[a] + tr, im[a] + ti
        size *= 2


def magnitudes(values, divisor):
    """One-sided |DFT| of real `values` (bins 0..n/2), divided by `divisor`."""
    re, im = list(values), [0.0] * len(values)
    complex_fft(re, im)
    return [math.sqrt(re[k] * re[k] + im[k] * im[k]) / divisor for k in range(len(values) // 2 + 1)]


def hann(n):
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) for i in range(n)]


# --- Version 2 model ---------------------------------------------------------------------------

def band_edge(cfg, edge):
    ratio = (cfg["spectrum_max_hz"] / cfg["spectrum_min_hz"]) ** (1.0 / cfg["spectrum_bands"])
    return cfg["spectrum_min_hz"] * ratio ** edge


def db_level(cfg, amplitude):
    floor_amp = 10.0 ** (cfg["db_floor"] / 20.0)
    db = 20.0 * math.log10(max(amplitude, floor_amp))
    return min(1.0, max(0.0, (db - cfg["db_floor"]) / -cfg["db_floor"]))


def bass_plan(cfg):
    """Decimation factor, window, FFT size and leading band count, or None when off."""
    fs, n = cfg["sample_rate_hz"], cfg["fft_window_samples"]
    factor = 1
    while fs > BASS_RATE_HZ * factor:
        factor *= 2
    if factor > BASS_MAX_DECIMATION:
        return None
    rate = fs / factor
    window = int(min(BASS_WINDOW, math.floor(rate * BASS_WINDOW / BASS_RATE_HZ)))
    bands = 0
    for band in range(cfg["spectrum_bands"]):
        lo, hi = band_edge(cfg, band), band_edge(cfg, band + 1)
        if not ((hi - lo) * n / fs < BASS_MAX_MAIN_BINS and hi <= BASS_TOP_FRACTION * rate):
            break
        bands += 1
    if window * factor <= n or bands == 0:
        return None
    size = 1
    while size < window:
        size *= 2
    return {"factor": factor, "window": window, "size": size, "bands": bands}


def cic_taps(factor):
    """Coefficients of ((1 + z + ... + z^(D-1)) / D)^4, from exact integer products."""
    poly = [1]
    for _ in range(CIC_ORDER):
        out = [0] * (len(poly) + factor - 1)
        for i, c in enumerate(poly):
            for j in range(factor):
                out[i + j] += c
        poly = out
    return [c / factor ** CIC_ORDER for c in poly]


def droop_gain(fs, factor, hz):
    if hz == 0:
        return 1.0
    x = math.pi * hz / fs
    response = (math.sin(factor * x) / (factor * math.sin(x))) ** 4
    return 1.0 / response


def triangle_weights(lo, hi, bin_count, spacing, gain):
    """{bin: weight}: triangle over bins strictly inside (lo, hi), unit sum, times gain(bin)."""
    centre = math.sqrt(lo * hi)
    weights = {}
    for k in range(bin_count):
        f = k * spacing
        if lo < f < hi:
            weights[k] = (f - lo) / (centre - lo) if f <= centre else (hi - f) / (hi - centre)
    if not weights:
        position = centre / spacing
        k0 = min(int(math.floor(position)), bin_count - 2)
        frac = min(1.0, max(0.0, position - k0))
        weights = {k0: 1.0 - frac, k0 + 1: frac}
    total = sum(weights.values())
    return {k: w / total * gain(k) for k, w in weights.items()}


class Model:
    def __init__(self, cfg):
        self.cfg = cfg
        fs, n = cfg["sample_rate_hz"], cfg["fft_window_samples"]
        self.window = hann(n)
        self.plan = bass_plan(cfg)
        bass_bands = self.plan["bands"] if self.plan else 0
        self.bands = []
        for band in range(cfg["spectrum_bands"]):
            lo, hi = band_edge(cfg, band), band_edge(cfg, band + 1)
            if band < bass_bands:
                plan = self.plan
                spacing = fs / (plan["factor"] * plan["size"])
                gain = lambda k, s=spacing, d=plan["factor"]: droop_gain(fs, d, k * s)
                weights = triangle_weights(lo, hi, plan["size"] // 2 + 1, spacing, gain)
                self.bands.append(("bass", weights))
            else:
                weights = triangle_weights(lo, hi, n // 2 + 1, fs / n, lambda k: 1.0)
                self.bands.append(("main", weights))
        if self.plan:
            self.taps = cic_taps(self.plan["factor"])
            self.bass_window = hann(self.plan["window"])
        ranges = [(cfg["spectrum_min_hz"], cfg["spectrum_max_hz"])]
        for start, end in cfg["onset_band_groups"]:
            ranges.append((band_edge(cfg, start), band_edge(cfg, end + 1)))
        self.onset_bins = [[k for k in range(n // 2 + 1) if lo <= k * fs / n < hi]
                           for lo, hi in ranges]
        self.onset_scale = n / sum(w * w for w in self.window)
        hop_sec = cfg["hop_samples"] / fs
        self.attack = math.exp(-hop_sec / (cfg["ballistics_attack_ms"] / 1000.0))
        self.release = math.exp(-hop_sec / (cfg["ballistics_release_ms"] / 1000.0))
        self.rms_window = int(math.trunc(fs * cfg["rms_window_ms"] / 1000.0))

    def decimate(self, segment):
        """y[j] = sum_t h[t] x[(j + 1) D - 1 - t], with x = 0 before the segment start."""
        factor, taps = self.plan["factor"], self.taps
        out = []
        for j in range(len(segment) // factor):
            newest = (j + 1) * factor - 1
            out.append(sum(h * segment[newest - t] for t, h in enumerate(taps) if newest - t >= 0))
        return out

    def bass_magnitudes(self, decimated, count):
        plan = self.plan
        length = plan["window"]
        padded = [0.0] * plan["size"]
        available = min(count, length)
        for i in range(available):
            slot = length - available + i
            padded[slot] = decimated[count - available + i] * self.bass_window[slot]
        return magnitudes(padded, length / 2.0)

    def run(self, chunks, replaced=()):
        """Frames for a list of (media_start_ms, samples, stalled) segments. `replaced` lists,
        per segment, the segment-relative indices of samples that were replaced with 0: the
        frame whose window end is the first after such an index carries flag 4, and an index
        after the segment's last frame sets no flag."""
        cfg = self.cfg
        fs, n, hop = cfg["sample_rate_hz"], cfg["fft_window_samples"], cfg["hop_samples"]
        hop_ms = hop / fs * 1000.0
        smoothed = [0.0] * cfg["spectrum_bands"]
        previous, peaks, started = [0.0] * 4, [0.0] * 4, False
        expected, frames = None, []
        for segment, (start_ms, samples, stalled) in enumerate(chunks):
            decimated = self.decimate(samples) if self.plan else []
            pending = sorted(replaced[segment]) if replaced else []
            first = True
            for end in range(n, len(samples) + 1, hop):
                main = magnitudes([s * w for s, w in zip(samples[end - n:end], self.window)], n / 2.0)
                bass = None
                if self.plan:
                    bass = self.bass_magnitudes(decimated, end // self.plan["factor"])
                raw = []
                for source, weights in self.bands:
                    spectrum = bass if source == "bass" else main
                    raw.append(db_level(cfg, sum(w * spectrum[k] for k, w in weights.items())))
                onset = [0.0] * 4
                for i, bins in enumerate(self.onset_bins):
                    energy = sum(main[k] * main[k] for k in bins)
                    level = db_level(cfg, math.sqrt(energy * self.onset_scale))
                    if started:
                        flux = max(0.0, level - previous[i])
                        peaks[i] = max(flux, peaks[i] * cfg["onset_peak_decay"])
                        onset[i] = flux / max(peaks[i], cfg["onset_peak_floor"], ONSET_FLOOR)
                    previous[i] = level
                started = True
                for i, r in enumerate(raw):
                    coeff = self.attack if r > smoothed[i] else self.release
                    smoothed[i] = r + coeff * (smoothed[i] - r)
                count = min(end, self.rms_window)
                rms = math.sqrt(sum(s * s for s in samples[end - count:end]) / count)
                loudness = 20.0 * math.log10(max(rms, cfg["rms_floor"])) - cfg["loudness_reference_lufs"]
                time_ms = start_ms + end / fs * 1000.0
                flags = 0
                if first:
                    tolerance = cfg["gap_tolerance_hops"] * hop_ms
                    if expected is not None and start_ms - expected > tolerance:
                        flags |= 1
                    if stalled:
                        flags |= 2
                first = False
                if pending and pending[0] < end:
                    flags |= 4
                    pending = [i for i in pending if i >= end]
                expected = round6(time_ms) + hop_ms
                frames.append((len(frames), flags, [time_ms, rms, loudness] + onset + list(smoothed)))
        return frames


# --- Output ------------------------------------------------------------------------------------

def round6(value):
    """Six decimals, half away from zero."""
    return math.copysign(math.floor(abs(value) * 1e6 + 0.5), value) / 1e6


def publish(value):
    text = ("%.6f" % round6(value)).rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def v1_header(name):
    """Signal description and chunk rows of the version 1 fixture."""
    signal, chunks = None, []
    with open(os.path.join(V1_DIR, name + ".frames")) as handle:
        for line in handle:
            if line.startswith("# signal:"):
                signal = line.split(":", 1)[1].strip()
            elif line.startswith("chunk "):
                fields = line.split()
                chunks.append((float(fields[1]), int(fields[2]), int(fields[3]), fields[4] == "1"))
    return signal, chunks


def kick_report(frames, seconds):
    """Smallest kick onset and largest between-kick onset (broadband), after 0.5 s."""
    window_ms = DEFAULT["fft_window_samples"] / 48.0
    kicks, between = [], 0.0
    for k in range(1, int(seconds / 0.5 + 0.5)):
        kick_ms = 500.0 * k
        values = [f[2][3] for f in frames if kick_ms < f[2][0] <= kick_ms + window_ms]
        kicks.append(max(values))
    for _, _, values in frames:
        time_ms = values[0]
        in_kick = any(500.0 * k < time_ms <= 500.0 * k + window_ms for k in range(1, 13))
        if time_ms > 500.0 and not in_kick:
            between = max(between, values[3])
    return min(kicks), between, len(kicks)


def edge_signal(name, rate, channels):
    """Interleaved 16-bit samples of an edge-case fixture, before replacement."""
    seconds = {"kicks-44k1": 1.5, "kicks-config-32k": 1.5}.get(name, 1.0)
    kick = kick_values(seconds, rate)
    if name == "kicks-config-32k":
        return [quantise(v + 0.2 * math.sin(2 * math.pi * 330.0 * i / rate))
                for i, v in enumerate(kick)]
    if name == "stereo-antiphase":
        pcm = []
        for i, v in enumerate(kick):
            treble = 0.3 * math.sin(2 * math.pi * 1000.0 * i / rate)
            bass = 0.1 * math.sin(2 * math.pi * 220.0 * i / rate)
            pcm += [quantise(v + treble + bass), quantise(v - treble + bass)]
        return pcm
    assert channels == 1, name
    return [quantise(v) for v in kick]


def config_value(value):
    if isinstance(value, tuple):
        return ",".join("%d-%d" % group for group in value)
    return publish(value) if isinstance(value, float) else str(value)


def edge_rows(overrides, channels, chunk_rows, replaced):
    """Definition rows shared by the `.spec` and both `.frames` files of an edge fixture."""
    rows = ["channels %d" % channels]
    rows += ["config %s %s" % (key, config_value(overrides[key]))
             for key in DEFAULT if key in overrides]
    rows += ["chunk %s %d %d %d" % (publish(s), b, e, int(st)) for s, b, e, st in chunk_rows]
    rows += ["replace %d %s" % (index, kind) for index, kind in replaced]
    return rows


def generate_edges(input_dir, v2_dir):
    """Writes each edge fixture's WAV and `.spec` into input_dir and its version 2 frames into
    v2_dir."""
    os.makedirs(v2_dir, exist_ok=True)
    for name, overrides, channels, signal, chunk_rows, replaced in EDGE_FIXTURES:
        cfg = dict(DEFAULT, **overrides)
        rate = cfg["sample_rate_hz"]
        pcm = edge_signal(name, rate, channels)
        for index, _ in replaced:
            pcm[index * channels:(index + 1) * channels] = [0] * channels
        path = os.path.join(input_dir, name + ".wav")
        with open(path, "wb") as handle:
            handle.write(wav_bytes(pcm, rate, channels))
        rows = edge_rows(overrides, channels, chunk_rows, replaced)
        with open(os.path.join(input_dir, name + ".spec"), "w") as handle:
            handle.write("\n".join(["# dsp-edge-spec v1", "# signal: %s" % signal] + rows) + "\n")
        wav_rate, samples = read_wav(path)
        assert wav_rate == rate, name
        spans = chunk_rows or [(0.0, 0, len(samples), False)]
        chunks = [(start, samples[begin:end], stalled) for start, begin, end, stalled in spans]
        per_segment = [[index - begin for index, _ in replaced if begin <= index < end]
                       for _, begin, end, _ in spans]
        frames = Model(cfg).run(chunks, per_segment)
        lines = [
            "# dsp-fixture v2",
            "# behavior_version 2; configuration: defaults overridden by the config rows; "
            "input conformance/dsp/music/%s.wav with the replace rows applied" % name,
            "# expected values: tools/dsp-v2-vectors.py (independent model of the README spec)",
            "# signal: %s" % signal,
        ] + rows
        lines.append("# frame seq flags media_time_ms rms loudness_db onset_broadband onset_low "
                     "onset_mid onset_high spectrum[%d]" % cfg["spectrum_bands"])
        for seq, flags, values in frames:
            lines.append(" ".join(["frame", str(seq), str(flags)] + [publish(v) for v in values]))
        with open(os.path.join(v2_dir, name + ".frames"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        flagged = ", ".join("%d:%d" % (seq, flags) for seq, flags, _ in frames if flags)
        print("%-22s %4d frames; flagged frames %s" % (name, len(frames), flagged or "none"))


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    reference = kick_pcm(2.0)
    with open(os.path.join(V1_DIR, "kicks-120bpm.wav"), "rb") as handle:
        if wav_bytes(reference, 48000) != handle.read():
            sys.exit("kick generator does not reproduce conformance/dsp/kicks-120bpm.wav")
    synth = {"kicks": kick_pcm(6.0), "sine60": sine_pcm(60.0, 0.5)}
    for name, rate, source in FIXTURES:
        cfg = dict(DEFAULT, sample_rate_hz=rate)
        if source:
            path = os.path.join(out_dir, name + ".wav")
            with open(path, "wb") as handle:
                handle.write(wav_bytes(synth[source], rate))
            signal, chunk_rows = SYNTH_SIGNALS[source], []
            origin = "conformance/dsp/v2/%s.wav" % name
        else:
            path = os.path.join(V1_DIR, name + ".wav")
            signal, chunk_rows = v1_header(name)
            origin = "conformance/dsp/%s.wav" % name
        wav_rate, samples = read_wav(path)
        assert wav_rate == rate, name
        spans = chunk_rows or [(0.0, 0, len(samples), False)]
        chunks = [(start, samples[begin:end], stalled) for start, begin, end, stalled in spans]
        frames = Model(cfg).run(chunks)
        lines = [
            "# dsp-fixture v2",
            "# behavior_version 2, sample_rate_hz %d, other fields default; input %s" % (rate, origin),
            "# expected values: tools/dsp-v2-vectors.py (independent model of the README spec)",
            "# signal: %s" % signal,
        ]
        lines += ["chunk %s %d %d %d" % (publish(s), b, e, int(st)) for s, b, e, st in chunk_rows]
        lines.append("# frame seq flags media_time_ms rms loudness_db onset_broadband onset_low "
                     "onset_mid onset_high spectrum[%d]" % cfg["spectrum_bands"])
        for seq, flags, values in frames:
            lines.append(" ".join(["frame", str(seq), str(flags)] + [publish(v) for v in values]))
        with open(os.path.join(out_dir, name + ".frames"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        report = "%-22s %4d frames" % (name, len(frames))
        if name.startswith("kicks-120bpm"):
            low, high, count = kick_report(frames, len(samples) / rate)
            report += "; %d kicks after 0.5 s: min onset %.4f, between-kick max %.4f" % (count, low, high)
        if name == "sine-60-full":
            last = frames[-1][2][7:]
            above = [i for i, v in enumerate(last) if v > 0.5]
            top = max(range(len(last)), key=lambda i: last[i])
            report += "; bands above 0.5: %s, highest band %d" % (above, top)
        print(report)


def compare(fresh, committed, names, label):
    """Problems of `committed` against `fresh` for the given generated file names."""
    have = sorted(names(committed)) if os.path.isdir(committed) else []
    wanted = sorted(names(fresh))
    _, changed, unreadable = filecmp.cmpfiles(fresh, committed, wanted, shallow=False)
    missing = [name for name in wanted if name not in have]
    extra = [name for name in have if name not in wanted]
    problems = [("changed", changed), ("missing", missing), ("not generated", extra),
                ("unreadable", [name for name in unreadable if name not in missing])]
    return ["%s %s: %s" % (label, kind, ", ".join(found)) for kind, found in problems if found]


def check():
    every = os.listdir
    inputs = lambda d: [n for n in os.listdir(d) if n.endswith((".wav", ".spec"))]
    with tempfile.TemporaryDirectory() as fresh:
        v2, edge = os.path.join(fresh, "v2"), os.path.join(fresh, "music")
        generate(v2)
        generate_edges(edge, os.path.join(edge, "v2"))
        problems = compare(v2, OUT_DIR, every, "conformance/dsp/v2/")
        problems += compare(os.path.join(edge, "v2"), EDGE_V2_DIR, every,
                            "conformance/dsp/music/v2/")
        problems += compare(edge, EDGE_DIR, inputs, "conformance/dsp/music/ inputs")
        counts = (len(every(v2)), len(every(os.path.join(edge, "v2"))), len(inputs(edge)))
    if problems:
        sys.exit("generated conformance files differ from the generator output; regenerate them\n"
                 + "\n".join(problems))
    print("conformance/dsp/v2/: %d files, conformance/dsp/music/v2/: %d files, "
          "conformance/dsp/music/ inputs: %d files match the generator" % counts)


def main():
    if sys.argv[1:] == ["--check"]:
        check()
    elif sys.argv[1:]:
        sys.exit("usage: python3 tools/dsp-v2-vectors.py [--check]")
    else:
        generate(OUT_DIR)
        generate_edges(EDGE_DIR, EDGE_V2_DIR)


if __name__ == "__main__":
    main()
