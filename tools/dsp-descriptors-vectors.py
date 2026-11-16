#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write the DSP descriptor vectors under conformance/dsp/descriptors/.

This is an independent standard-library model (no numpy, no downloads) of the opt-in
descriptors that oscillux_dsp_push_ext_* return beside each frame (OSC-DSP-DESCRIPTORS), written
from conformance/dsp/README.md and the OscilluxDspDescriptors documentation in oscillux.h. It
shares no code or intermediate values with the Rust analyzer and computes differently where the
definitions allow: direct-form I K-weighting filters (Rust uses transposed direct form II),
exact float window sums with math.fsum over each window (Rust differences 128-bit cumulative
sums of quantised powers), and one complex FFT of two real windows at once.

It writes three files:

- k-weighting.json: the BS.1770-4 K-weighting biquads for common sample rates, derived from the
  analog prototype parameters as libebur128 does (the Rust analyzer uses the same derivation,
  so these coefficients alone do not test it independently). The script therefore checks the
  derivation against the published BS.1770-4 filter, which it evaluates on its own: the 48 kHz
  coefficients within 1e-12 of Tables 1 and 2, and every rate's magnitude response within
  RESPONSE_DB of the published 48 kHz biquads' |H(e^jw)|, at 1 kHz for every rate and from 10 Hz
  to the lower of WIDE_TOP_HZ and WIDE_TOP_FRACTION of the rate for rates of at least
  WIDE_RATE_HZ. Each rate records its largest deviation and the band it was measured over. Like
  libebur128, the derivation keeps the high-pass numerator (1, -2, 1), and the bilinear
  transform compresses the shelf near Nyquist, so rates below WIDE_RATE_HZ deviate more (the
  script prints the worst case up to 3 kHz).
- tech3341.json: the analytic EBU Tech 3341 sine cases 1, 2, 6, 9 and 12 plus 5.1 and 7.1 LFE,
  mono, anti-phase, left-only, DC-offset and DC-only signals and 100 Hz and 10 kHz sines at 44.1
  and 48 kHz, with momentary and short-term loudness, width and balance at every frame. Each
  case states the Tech 3341 or analytic nominal value, and the script fails unless its own
  values meet it within the stated tolerance. The 100 Hz, 10 kHz and 7.1 nominal values come
  from the published 48 kHz biquads' gain at the tone frequency and the BS.1770-4 channel
  weights written out per case, not from the derived filters or channel_weight.
- centroid.json: per frame, the spectral centroid by the librosa definition (periodic Hann,
  |STFT| magnitudes, sum f_k |X_k| / sum |X_k| with f_k = k fs / N), the centroid and the
  spectral flux by the analyzer's documented definition (symmetric Hann), for the WAV fixtures
  in conformance/dsp/ and a synthesised 44.1 kHz sweep.

Usage: python3 tools/dsp-descriptors-vectors.py
       python3 tools/dsp-descriptors-vectors.py --check   (exit 1 if the directory differs)

--check writes into a temporary directory and compares it with conformance/dsp/descriptors/
file by file, so a missing, extra or changed file fails.
"""

import filecmp
import json
import math
import os
import struct
import sys
import tempfile
import wave

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DSP_DIR = os.path.join(ROOT, "conformance", "dsp")
OUT_NAME = "descriptors"

FFT_WINDOW = 2048
HOP = 512
LUFS_FLOOR = -120.0
MOMENTARY_SECONDS = 0.4
SHORT_TERM_SECONDS = 3.0
# At or below this mean left/right energy over the momentary window, width and balance are written as
# null: the analyzer quantises powers to 2^-50, so tiny energies do not give comparable ratios.
RATIO_MIN_ENERGY = 1e-8
NOMINAL_LU = 0.1
NOMINAL_RATIO = 1e-3
RESPONSE_DB = 0.05
WIDE_RATE_HZ = 32000
WIDE_TOP_HZ = 20000.0
WIDE_TOP_FRACTION = 0.45
RATES = (8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 192000)

# BS.1770-4 Tables 1 and 2: the 48 kHz shelf (b0 b1 b2 a1 a2) and RLB high-pass (a1 a2).
PUBLISHED_SHELF = (1.53512485958697, -2.69169618940638, 1.19839281085285,
                   -1.69065929318241, 0.73248077421585)
PUBLISHED_HIGH_PASS = (-1.99004745483398, 0.99007225036621)
PUBLISHED = ((list(PUBLISHED_SHELF[:3]), list(PUBLISHED_SHELF[3:])),
             ([1.0, -2.0, 1.0], list(PUBLISHED_HIGH_PASS)))


# ---- K-weighting ----------------------------------------------------------------------------

def k_weighting(rate):
    """((shelf_b, shelf_a), (high_pass_b, high_pass_a)) for `rate`, a = (a1, a2)."""
    f0, gain_db, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = math.tan(math.pi * f0 / rate)
    vh = 10.0 ** (gain_db / 20.0)
    vb = vh ** 0.4996667741545416
    a0 = 1.0 + k / q + k * k
    shelf = ([(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
             [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0])
    f0, q = 38.13547087602444, 0.5003270373238773
    k = math.tan(math.pi * f0 / rate)
    a0 = 1.0 + k / q + k * k
    high_pass = ([1.0, -2.0, 1.0], [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0])
    return shelf, high_pass


def response_db(stages, rate, hz):
    w = 2.0 * math.pi * hz / rate
    z1, z2 = complex(math.cos(w), -math.sin(w)), complex(math.cos(2 * w), -math.sin(2 * w))
    total = 1.0
    for b, a in stages:
        total *= abs((b[0] + b[1] * z1 + b[2] * z2) / (1.0 + a[0] * z1 + a[1] * z2))
    return 20.0 * math.log10(total)


def published_db(hz):
    """K-weighting gain in dB at `hz` of the published BS.1770-4 48 kHz biquads."""
    return response_db(PUBLISHED, 48000, hz)


def k_weighting_doc():
    shelf, high_pass = k_weighting(48000)
    derived = shelf[0] + shelf[1]
    for got, want in zip(derived + high_pass[1], PUBLISHED_SHELF + PUBLISHED_HIGH_PASS):
        if abs(got - want) > 1e-12:
            sys.exit(f"k-weighting: 48 kHz derivation {got!r} differs from BS.1770-4 {want!r}")
    checked = narrow = 0.0
    rates = []
    for rate in RATES:
        stages = k_weighting(rate)
        wide = rate >= WIDE_RATE_HZ
        top = min(WIDE_TOP_HZ, WIDE_TOP_FRACTION * rate) if wide else 3000.0
        points, hz = [1000.0, top], 10.0
        while hz < top:
            points.append(hz)
            hz *= 1.25
        worst = max(abs(response_db(stages, rate, hz) - published_db(hz)) for hz in points)
        if wide:
            checked = max(checked, worst)
        else:
            narrow = max(narrow, worst)
            checked = max(checked, abs(response_db(stages, rate, 1000.0) - published_db(1000.0)))
        rates.append({
            "sample_rate_hz": rate,
            "shelf": {"b": stages[0][0], "a": stages[0][1]},
            "high_pass": {"b": stages[1][0], "a": stages[1][1]},
            "response_band_hz": [10.0, top],
            "max_response_deviation_db": round(worst, 4),
        })
    if checked > RESPONSE_DB:
        sys.exit(f"k-weighting: response deviates {checked:.4f} dB from the published 48 kHz filter")
    wide_44k = next(r for r in rates if r["sample_rate_hz"] == 44100)
    print(f"k-weighting: 48 kHz matches BS.1770-4 within 1e-12; response within {checked:.4f} dB of the "
          f"published 48 kHz biquads at 1 kHz for {len(RATES)} rates and from 10 Hz to "
          f"min({WIDE_TOP_HZ:g} Hz, {WIDE_TOP_FRACTION} rate) from {WIDE_RATE_HZ} Hz (44.1 kHz to "
          f"{wide_44k['response_band_hz'][1]:g} Hz: {wide_44k['max_response_deviation_db']} dB; "
          f"below {WIDE_RATE_HZ} Hz up to 3 kHz: {narrow:.4f} dB)")
    return {
        "description": "BS.1770-4 K-weighting biquads (shelf, then RLB high-pass) derived for each "
                       "sample rate by tools/dsp-descriptors-vectors.py. Denominators are (a1, a2) "
                       "with a0 = 1. max_response_deviation_db is the largest magnitude-response "
                       "difference from the published BS.1770-4 48 kHz biquads over "
                       "response_band_hz (geometric steps of 1.25 from 10 Hz, plus 1 kHz and the "
                       "top). From 32 kHz it is at most response_tolerance_db; below 32 kHz only "
                       "the 1 kHz difference is held to it.",
        "tolerance": 1e-12,
        "response_tolerance_db": RESPONSE_DB,
        "rates": rates,
    }


# ---- Loudness, width and balance -------------------------------------------------------------

def channel_weight(channels, index):
    """BS.1770-4 channel weights: Ls Rs 1.41, LFE excluded, others 1. Five channels are
    L R C Ls Rs, six L R C LFE Ls Rs and eight L R C LFE Ls Rs Lrs Rrs (ITU-R BS.2051 system I
    order), whose rear surrounds lie outside 60-120 degrees azimuth and weigh 1."""
    if channels == 5 and index in (3, 4):
        return 1.41
    if channels in (6, 8):
        return {3: 0.0, 4: 1.41, 5: 1.41}.get(index, 1.0)
    return 1.0


def k_filter(x, rate):
    """Direct form I, shelf then high-pass."""
    (sb, sa), (hb, ha) = k_weighting(rate)
    out = []
    x1 = x2 = y1 = y2 = z1 = z2 = 0.0
    for v in x:
        y = sb[0] * v + sb[1] * x1 + sb[2] * x2 - sa[0] * y1 - sa[1] * y2
        z = hb[0] * y + hb[1] * y1 + hb[2] * y2 - ha[0] * z1 - ha[1] * z2
        x2, x1, y2, y1, z2, z1 = x1, v, y1, y, z1, z
        out.append(z)
    return out


def channel_signal(case, channel):
    """Samples of one channel, as the Rust test synthesises them."""
    rate, f, samples = case["sample_rate_hz"], case["frequency_hz"], case["samples"]
    gain, sign, dc = channel["gain_db"], channel["sign"], channel["dc"]
    levels = case["levels"] or [[samples, 0.0]]
    period = sum(length for length, _ in levels)
    amplitudes = []
    for length, offset in levels:
        amplitude = 0.0 if gain is None else sign * 10.0 ** ((gain + offset) / 20.0)
        amplitudes += [amplitude] * length
    return [amplitudes[n % period] * math.sin(2.0 * math.pi * f * n / rate) + dc for n in range(samples)]


def frame_ends(samples):
    return range(FFT_WINDOW, samples + 1, HOP)


def lufs(total, count):
    if total <= 0.0:
        return LUFS_FLOOR
    return max(-0.691 + 10.0 * math.log10(total / count), LUFS_FLOOR)


def measure(case, cache):
    rate, channels = case["sample_rate_hz"], case["channels"]
    weighted = []
    for channel in channels:
        key = (rate, case["frequency_hz"], case["samples"], json.dumps(case["levels"]),
               channel["gain_db"], channel["sign"], channel["dc"])
        if key not in cache:
            cache[key] = k_filter(channel_signal(case, channel), rate)
        weighted.append(cache[key])
    count = len(channels)
    weights = [channel_weight(count, i) for i in range(count)]
    power = [math.fsum(w * y[n] * y[n] for w, y in zip(weights, weighted)) for n in range(case["samples"])]
    stereo = count >= 2
    if stereo:
        left = [y * y for y in weighted[0]]
        right = [y * y for y in weighted[1]]
        side = [((a - b) * 0.5) ** 2 for a, b in zip(weighted[0], weighted[1])]
    momentary_len = round(MOMENTARY_SECONDS * rate)
    short_len = round(SHORT_TERM_SECONDS * rate)
    rows = []
    for end in frame_ends(case["samples"]):
        m0, s0 = max(end - momentary_len, 0), max(end - short_len, 0)
        row = [lufs(math.fsum(power[m0:end]), end - m0), lufs(math.fsum(power[s0:end]), end - s0)]
        if not stereo:
            row += [0.0, 0.0]
        else:
            el, er, es = (math.fsum(v[m0:end]) for v in (left, right, side))
            half = (el + er) * 0.5
            if half / (end - m0) <= RATIO_MIN_ENERGY:
                row += [None, None]
            else:
                row += [min(max(es / half, 0.0), 1.0), min(max((er - el) / (er + el), -1.0), 1.0)]
        rows.append(row)
    return rows


def tone(gain_db, sign=1, dc=0.0):
    return {"gain_db": gain_db, "sign": sign, "dc": dc}


def sine_lufs(gains_db, weights, hz):
    """Analytic loudness of steady sines at `hz` with these channel gains and BS.1770-4 weights:
    -0.691 + 10 log10(sum G_i A_i^2 / 2) plus the published 48 kHz biquads' gain at `hz`."""
    power = math.fsum(w * 10.0 ** (g / 10.0) / 2.0 for g, w in zip(gains_db, weights))
    return -0.691 + 10.0 * math.log10(power) + published_db(hz)


def loudness_cases():
    """(name, source, frequency, seconds, channels, levels in seconds, nominal)."""
    stereo = [tone(-23), tone(-23)]
    mono_nominal = -23.0 - 10.0 * math.log10(2.0)
    steady = 0.8
    surround = [-28, -28, -24, -10, -30, -30, -30, -30]
    surround_nominal = sine_lufs(surround, [1, 1, 1, 0, 1.41, 1.41, 1, 1], 1000.0)
    low_nominal = sine_lufs([-23, -23], [1, 1], 100.0)
    high_nominal = sine_lufs([-23, -23], [1, 1], 10000.0)
    return [
        ("case1", "EBU Tech 3341 case 1: stereo 1 kHz at -23 dBFS", 1000.0, steady, stereo, [],
         {"momentary_lufs": -23.0, "short_term_lufs": -23.0, "width": 0.0, "balance": 0.0, "from_seconds": 0.5}),
        ("case2", "EBU Tech 3341 case 2: stereo 1 kHz at -33 dBFS", 1000.0, steady, [tone(-33), tone(-33)], [],
         {"momentary_lufs": -33.0, "short_term_lufs": -33.0, "width": 0.0, "balance": 0.0, "from_seconds": 0.5}),
        ("case6", "EBU Tech 3341 case 6: 5.0 L R -28, C -24, Ls Rs -30 dBFS", 1000.0, steady,
         [tone(-28), tone(-28), tone(-24), tone(-30), tone(-30)], [],
         {"momentary_lufs": -23.0, "short_term_lufs": -23.0, "width": 0.0, "balance": 0.0, "from_seconds": 0.5}),
        ("case6-lfe", "Tech 3341 case 6 as 5.1 with LFE at -10 dBFS, which BS.1770-4 excludes", 1000.0, steady,
         [tone(-28), tone(-28), tone(-24), tone(-10), tone(-30), tone(-30)], [],
         {"momentary_lufs": -23.0, "short_term_lufs": -23.0, "width": 0.0, "balance": 0.0, "from_seconds": 0.5}),
        ("case9", "EBU Tech 3341 case 9: stereo 1.34 s at -20 then 1.66 s at -30 dBFS, repeated", 1000.0, 3.5,
         [tone(-20), tone(-20)], [[1.34, 0.0], [1.66, -10.0]],
         {"momentary_lufs": None, "short_term_lufs": -23.0, "width": 0.0, "balance": 0.0, "from_seconds": 3.0}),
        ("case12", "EBU Tech 3341 case 12: stereo 0.18 s at -20 then 0.22 s at -30 dBFS, repeated", 1000.0, 1.2,
         [tone(-20), tone(-20)], [[0.18, 0.0], [0.22, -10.0]],
         {"momentary_lufs": -23.0, "short_term_lufs": None, "width": 0.0, "balance": 0.0, "from_seconds": 0.4}),
        ("mono", "mono 1 kHz at -23 dBFS: one channel, so 10 log10(2) below stereo", 1000.0, steady, [tone(-23)], [],
         {"momentary_lufs": mono_nominal, "short_term_lufs": mono_nominal, "width": 0.0, "balance": 0.0,
          "from_seconds": 0.5}),
        ("anti-phase", "stereo 1 kHz at -23 dBFS with R = -L: loudness as case 1, width 1", 1000.0, steady,
         [tone(-23), tone(-23, sign=-1)], [],
         {"momentary_lufs": -23.0, "short_term_lufs": -23.0, "width": 1.0, "balance": 0.0, "from_seconds": 0.5}),
        ("left-only", "1 kHz at -23 dBFS on L, R silent: width 0.5, balance -1", 1000.0, steady, [tone(-23), tone(None)], [],
         {"momentary_lufs": mono_nominal, "short_term_lufs": mono_nominal, "width": 0.5, "balance": -1.0,
          "from_seconds": 0.5}),
        ("dc-offset", "case 1 plus a 0.25 DC offset, which the RLB high-pass removes", 1000.0, steady,
         [tone(-23, dc=0.25), tone(-23, dc=0.25)], [],
         {"momentary_lufs": -23.0, "short_term_lufs": None, "width": 0.0, "balance": 0.0, "from_seconds": 0.6}),
        ("dc-only", "a 0.5 DC level on both channels: nothing passes the high-pass once it settles", 1000.0, steady,
         [tone(None, dc=0.5), tone(None, dc=0.5)], [],
         {"momentary_lufs": LUFS_FLOOR, "short_term_lufs": None, "width": None, "balance": None,
          "from_seconds": 0.7}),
        ("case6-7.1", "Tech 3341 case 6 as 7.1 (L R C LFE Ls Rs Lrs Rrs) with LFE at -10 and rear "
         "surrounds at -30 dBFS: LFE weight 0, rear weight 1", 1000.0, steady,
         [tone(g) for g in surround], [],
         {"momentary_lufs": surround_nominal, "short_term_lufs": surround_nominal, "width": 0.0, "balance": 0.0,
          "from_seconds": 0.5}),
        ("sine-100hz", "stereo 100 Hz at -23 dBFS: K-weighting gain from the published 48 kHz biquads",
         100.0, steady, stereo, [],
         {"momentary_lufs": low_nominal, "short_term_lufs": low_nominal, "width": 0.0, "balance": 0.0,
          "from_seconds": 0.5}),
        ("sine-10khz", "stereo 10 kHz at -23 dBFS: K-weighting gain from the published 48 kHz biquads",
         10000.0, steady, stereo, [],
         {"momentary_lufs": high_nominal, "short_term_lufs": high_nominal, "width": 0.0, "balance": 0.0,
          "from_seconds": 0.5}),
    ]


def check_nominal(case, rows):
    nominal = case["nominal"]
    for index, row in enumerate(rows[nominal["from_frame"]:], nominal["from_frame"]):
        for slot, key, tolerance in ((0, "momentary_lufs", NOMINAL_LU), (1, "short_term_lufs", NOMINAL_LU),
                                     (2, "width", NOMINAL_RATIO), (3, "balance", NOMINAL_RATIO)):
            want = nominal[key]
            if want is not None and (row[slot] is None or abs(row[slot] - want) > tolerance):
                sys.exit(f"tech3341: {case['name']} at {case['sample_rate_hz']} Hz frame {index} "
                         f"{key} {row[slot]!r}, nominal {want} +- {tolerance}")


def tech3341_doc():
    cache = {}
    cases = []
    worst = 0.0
    for rate in (48000, 44100):
        for name, source, frequency, seconds, channels, levels, nominal in loudness_cases():
            samples = round(seconds * rate)
            from_frame = next(i for i, end in enumerate(frame_ends(samples)) if end >= nominal["from_seconds"] * rate)
            case = {
                "name": name,
                "source": source,
                "sample_rate_hz": rate,
                "samples": samples,
                "frequency_hz": frequency,
                "channels": channels,
                "levels": [[round(length * rate), offset] for length, offset in levels],
                "nominal": {key: value for key, value in nominal.items() if key != "from_seconds"},
            }
            case["nominal"]["from_frame"] = from_frame
            rows = measure(case, cache)
            check_nominal(case, rows)
            for row in rows[from_frame:]:
                for slot in (0, 1):
                    if nominal[("momentary_lufs", "short_term_lufs")[slot]] is not None:
                        worst = max(worst, abs(row[slot] - nominal[("momentary_lufs", "short_term_lufs")[slot]]))
            case["frames"] = rows
            cases.append(case)
    print(f"tech3341: {len(cases)} cases, {sum(len(c['frames']) for c in cases)} frames; every nominal "
          f"met, loudness within {worst:.4f} LU of nominal")
    return {
        "description": "Momentary and short-term loudness (LUFS), width and balance per frame, from "
                       "tools/dsp-descriptors-vectors.py. Frames end at samples 2048 + 512 k of one "
                       "segment. Channel c of sample n is sign * 10^((gain_db + offset_db) / 20) * "
                       "sin(2 pi frequency_hz n / sample_rate_hz) + dc, where offset_db cycles through "
                       "levels ([samples, offset_db] pairs; none means 0) and a null gain_db is silent. "
                       "Rows are [momentary_lufs, short_term_lufs, width, balance]; null width and "
                       "balance mark windows whose mean left/right energy is at most "
                       f"{RATIO_MIN_ENERGY:g}. Nominal values hold from frame from_frame within "
                       "nominal_lu (loudness) and nominal_ratio (width, balance).",
        "fft_window_samples": FFT_WINDOW,
        "hop_samples": HOP,
        "nominal_lu": NOMINAL_LU,
        "nominal_ratio": NOMINAL_RATIO,
        "power_relative_tolerance": 1e-9,
        "ratio_tolerance": 1e-6,
        "cases": cases,
    }


# ---- Centroid and flux -------------------------------------------------------------------

def fft_tables(n):
    bits = n.bit_length() - 1
    rev = [int(format(i, f"0{bits}b")[::-1], 2) for i in range(n)]
    return rev, [math.cos(2.0 * math.pi * k / n) for k in range(n // 2)], [-math.sin(2.0 * math.pi * k / n) for k in range(n // 2)]


def fft(re, im, tables):
    rev, cos_t, sin_t = tables
    re, im = [re[i] for i in rev], [im[i] for i in rev]
    n, size = len(re), 2
    while size <= n:
        half, step = size // 2, n // size
        twiddles = [(cos_t[k * step], sin_t[k * step]) for k in range(half)]
        for start in range(0, n, size):
            for k, (wr, wi) in enumerate(twiddles):
                i, j = start + k, start + k + half
                tr = wr * re[j] - wi * im[j]
                ti = wr * im[j] + wi * re[j]
                re[j], im[j] = re[i] - tr, im[i] - ti
                re[i], im[i] = re[i] + tr, im[i] + ti
        size *= 2
    return re, im


def spectral_rows(samples, rate, tables):
    """[librosa centroid, documented centroid, documented flux] per frame."""
    n = FFT_WINDOW
    periodic = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / n) for i in range(n)]
    symmetric = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1)) for i in range(n)]
    bin_hz = rate / n
    previous = None
    rows = []
    for end in frame_ends(len(samples)):
        window = samples[end - n:end]
        # One complex FFT of a + i b gives both real spectra:
        # A_k = (Z_k + conj Z_(n-k)) / 2, B_k = (Z_k - conj Z_(n-k)) / 2i.
        zr, zi = fft([x * w for x, w in zip(window, periodic)], [x * w for x, w in zip(window, symmetric)], tables)
        a, b = [], []
        for k in range(n // 2 + 1):
            rr, ri = zr[(n - k) % n], -zi[(n - k) % n]
            a.append(math.hypot(zr[k] + rr, zi[k] + ri) * 0.5)
            b.append(math.hypot(zi[k] - ri, zr[k] - rr) * 0.5)
        row = []
        for mags in (a, b):
            total = math.fsum(mags)
            row.append(math.fsum(k * bin_hz * m for k, m in enumerate(mags)) / total if total > 0 else 0.0)
        total = math.fsum(b)
        if previous is None or total <= 0:
            flux = 0.0
        else:
            flux = min(max(math.fsum(max(m - p, 0.0) for m, p in zip(b, previous)) / total, 0.0), 1.0)
        previous = b
        rows.append(row + [flux])
    return rows


def read_wav(path):
    with wave.open(path, "rb") as handle:
        assert handle.getnchannels() == 1 and handle.getsampwidth() == 2
        raw = handle.readframes(handle.getnframes())
        rate = handle.getframerate()
    return [v / 32768.0 for v in struct.unpack(f"<{len(raw) // 2}h", raw)], rate


def sweep(rate, samples, amplitude, f0, f1):
    """Exponential sweep, as the Rust test synthesises it."""
    seconds = samples / rate
    k = math.log(f1 / f0)
    return [amplitude * math.sin(2.0 * math.pi * f0 * seconds / k * (math.exp(n / rate / seconds * k) - 1.0))
            for n in range(samples)]


def centroid_doc():
    tables = fft_tables(FFT_WINDOW)
    inputs = []
    for name in sorted(os.listdir(DSP_DIR)) + ["v2/sine-60-full.wav"]:
        if not name.endswith(".wav"):
            continue
        samples, rate = read_wav(os.path.join(DSP_DIR, name))
        inputs.append({"name": name[:-4], "wav": "conformance/dsp/" + name, "sample_rate_hz": rate,
                       "frames": spectral_rows(samples, rate, tables)})
    synth = {"sample_rate_hz": 44100, "samples": 44100, "amplitude": 0.5, "f0": 40.0, "f1": 16000.0}
    inputs.append({"name": "sweep-40-16k-44k1", "sweep": synth, "sample_rate_hz": 44100,
                   "frames": spectral_rows(sweep(synth["sample_rate_hz"], synth["samples"], synth["amplitude"],
                                                 synth["f0"], synth["f1"]), 44100, tables)})
    worst = 0.0
    for item in inputs:
        for librosa, documented, _ in item["frames"]:
            if librosa > 0:
                worst = max(worst, abs(documented - librosa) / librosa)
    print(f"centroid: {len(inputs)} inputs, {sum(len(i['frames']) for i in inputs)} frames; the symmetric-Hann "
          f"centroid is within {100 * worst:.3f}% of the librosa definition")
    return {
        "description": "Per frame [librosa_centroid_hz, centroid_hz, spectral_flux] from "
                       "tools/dsp-descriptors-vectors.py, over one segment holding the whole input "
                       "(mono, frames ending at samples 2048 + 512 k). librosa_centroid_hz uses a "
                       "periodic Hann window, as librosa.feature.spectral_centroid does; centroid_hz "
                       "and spectral_flux use the analyzer's symmetric Hann window and the definitions "
                       "in oscillux.h. A sweep input is amplitude * sin(2 pi f0 T / ln(f1 / f0) * "
                       "(exp(n / sample_rate_hz / T * ln(f1 / f0)) - 1)) with T = samples / "
                       "sample_rate_hz.",
        "fft_window_samples": FFT_WINDOW,
        "hop_samples": HOP,
        "librosa_relative_tolerance": 0.02,
        "definition_relative_tolerance": 1e-9,
        "flux_tolerance": 1e-9,
        "inputs": inputs,
    }


# ---- Output --------------------------------------------------------------------------------

def dump(value, indent=0):
    """JSON with two-space indentation and scalar lists on one line."""
    pad, inner = "  " * indent, "  " * (indent + 1)
    if isinstance(value, dict):
        items = [f"{inner}{json.dumps(k)}: {dump(v, indent + 1)}" for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if all(not isinstance(v, (dict, list)) for v in value):
            return "[" + ", ".join(dump(v) for v in value) + "]"
        return "[\n" + ",\n".join(inner + dump(v, indent + 1) for v in value) + "\n" + pad + "]"
    if isinstance(value, float):
        if not math.isfinite(value):
            sys.exit("non-finite value")
        return repr(value)
    return json.dumps(value)


def write(directory):
    os.makedirs(directory, exist_ok=True)
    for name, doc in (("k-weighting.json", k_weighting_doc()), ("tech3341.json", tech3341_doc()),
                      ("centroid.json", centroid_doc())):
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            handle.write(dump(doc) + "\n")


def main():
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__)
    target = os.path.join(DSP_DIR, OUT_NAME)
    if sys.argv[1:] == []:
        write(target)
        return
    with tempfile.TemporaryDirectory() as scratch:
        fresh = os.path.join(scratch, OUT_NAME)
        write(fresh)
        if not os.path.isdir(target):
            sys.exit("dsp-descriptors-vectors: conformance/dsp/descriptors/ is missing")
        compared = filecmp.dircmp(fresh, target)
        stale = compared.left_only + compared.right_only + compared.diff_files + compared.funny_files
        _, mismatch, errors = filecmp.cmpfiles(fresh, target, compared.common_files, shallow=False)
        if stale or mismatch or errors:
            sys.exit("dsp-descriptors-vectors: conformance/dsp/descriptors/ is stale "
                     f"({sorted(set(stale + mismatch + errors))}); run python3 tools/dsp-descriptors-vectors.py")
    print("dsp-descriptors-vectors: conformance/dsp/descriptors/ matches")


if __name__ == "__main__":
    main()
