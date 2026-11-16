#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/limiter/cadence-sequences.json to stdout.

Expected values come from two sources that must agree before anything is written:

- a model of the rules stated in conformance/limiter/README.md, written from that text rather
  than from the Rust limiter, and
- the admitted flash times worked out by hand for each case, recorded in its `derivation`.

The model covers continuous streams only (every gap at most MAX_CREDITED_GAP_MS, no reset);
discontinuities are specified by timeline-sequences.json. Times are multiples of 0.25 ms and
so are exact in binary, which keeps every window and spacing comparison exact.

Usage: python3 tools/limiter-cadence-vectors.py > conformance/limiter/cadence-sequences.json
"""

import json
import math
import sys

THRESHOLD = 0.8
WINDOW_MS = 1000.0
MAX_CREDITED_GAP_MS = 250.0
ATTENUATED = 0.4
ONSETS = ("broadband", "low", "mid", "high")
FIELDS = ("timeMs",) + ONSETS + ("red", "area")
DEFAULT_POLICY = {
    "maxFlashHz": 3,
    "maxLuminanceDelta": 0.8,
    "maxFlashArea": 0.25,
    "maxRedFlashes": 3,
    "strobeBanned": True,
}


def quarter(ms):
    """Rounds a time to the nearest 0.25 ms."""
    return math.floor(ms * 4 + 0.5) / 4


def frame(time_ms, broadband=0.0, low=0.0, mid=0.0, high=0.0, red=0.0, area=0.0):
    return {"timeMs": time_ms, "broadband": broadband, "low": low, "mid": mid, "high": high,
            "red": red, "area": area}


def regular(a, b, c):
    """README: three flashes inside one window whose two gaps differ by at most 25%."""
    g1, g2 = b - a, c - b
    return c - a < WINDOW_MS and g1 > 0 and g2 > 0 and abs(g1 - g2) <= 0.25 * max(g1, g2)


def in_window(times, now):
    """Admitted flashes less than one window old; an event exactly 1000 ms old has left."""
    return [t for t in times if now - t < WINDOW_MS]


def limit(frames, policy):
    """Applies the README rules; returns (output, admitted general times, admitted red times)."""
    level = min(math.floor(policy["maxLuminanceDelta"] * 1e6) / 1e6, policy["maxLuminanceDelta"])
    area = policy["maxFlashArea"]
    general, red = [], []
    admitted_general, admitted_red = [], []
    out = []
    previous = None
    for f in frames:
        now = f["timeMs"]
        assert previous is None or 0 <= now - previous <= MAX_CREDITED_GAP_MS, now
        previous = now
        o = dict(f)
        # Flashes are judged on the input, before the luminance ceiling (OSC-LIMITER-CAP-THRESHOLD).
        if f["broadband"] >= THRESHOLD and f["area"] > area:
            general = in_window(general, now)
            over_rate = len(general) + 1 > policy["maxFlashHz"]
            strobe = len(general) >= 2 and regular(general[-2], general[-1], now)
            if over_rate or strobe:
                o["broadband"] = ATTENUATED
                for k in ("low", "mid", "high"):
                    o[k] = min(o[k], ATTENUATED)
            else:
                general.append(now)
                admitted_general.append(now)
        if f["red"] >= THRESHOLD and f["area"] > area:
            red = in_window(red, now)
            if len(red) >= policy["maxRedFlashes"]:
                o["red"] = ATTENUATED
            else:
                red.append(now)
                admitted_red.append(now)
        for k in ONSETS:
            o[k] = min(o[k], level)
        out.append(o)
    return out, admitted_general, admitted_red


def peak_window(times):
    return max((sum(1 for u in times if t <= u < t + WINDOW_MS) for t in times), default=0)


def analyze(frames, policy):
    area = policy["maxFlashArea"]
    flashes = [f["timeMs"] for f in frames if f["broadband"] >= THRESHOLD and f["area"] > area]
    reds = [f["timeMs"] for f in frames if f["red"] >= THRESHOLD and f["area"] > area]
    return {
        "peakFlashHz": peak_window(flashes),
        "peakLuminanceDelta": max((f["broadband"] for f in frames), default=0),
        "strobeDetected": any(regular(*flashes[i:i + 3]) for i in range(len(flashes) - 2)),
        "peakRedFlashes": peak_window(reds),
    }


def exceeds(a, policy):
    return (a["peakFlashHz"] > policy["maxFlashHz"]
            or a["peakLuminanceDelta"] > policy["maxLuminanceDelta"]
            or a["strobeDetected"]
            or a["peakRedFlashes"] > policy["maxRedFlashes"])


def grid(hz, start_ms, end_ms, jitter=(0,)):
    """Frame times at `hz` from `start_ms` (inclusive) to `end_ms` (exclusive), each nominal
    time rounded to 0.25 ms and then offset by the jitter pattern in turn."""
    times = []
    i = 0
    while True:
        nominal = start_ms + quarter(i * 1000.0 / hz)
        if nominal >= end_ms:
            return times
        times.append(nominal + jitter[i % len(jitter)])
        i += 1


def full_flash(t):
    return frame(t, broadband=1, low=0.9, mid=0.85, high=1, area=1)


def case(name, derivation, policy, frames, general, red=()):
    out, got_general, got_red = limit(frames, policy)
    assert got_general == list(general), (name, got_general)
    assert got_red == list(red), (name, got_red)
    before, after = analyze(frames, policy), analyze(out, policy)
    return {
        "name": name,
        "derivation": derivation,
        "policy": policy,
        "input": frames,
        "analysis": before,
        "exceeds": exceeds(before, policy),
        "clamped": out,
        "clampedAnalysis": after,
        "clampedExceeds": exceeds(after, policy),
    }


def cap_cases():
    tight = dict(DEFAULT_POLICY, maxLuminanceDelta=0.79)
    frames = [frame(t, broadband=1, low=1, mid=1, high=1, area=1) for t in grid(60, 0, 1051)]
    ramp = [frame(t, broadband=round(min(0.5 + i / 120, 1.0), 4), low=round(min(0.5 + i / 120, 1.0), 4),
                  area=1) for i, t in enumerate(grid(60, 0, 1200))]
    return [
        case("cap-0.79-60hz-every-frame-onsets",
             "OSC-LIMITER-CAP-THRESHOLD. Every 60 Hz frame is a full-screen 1.0 onset; the cap is "
             "0.79. Flashes are judged before the cap, so admission matches the default policy: "
             "0 and 16.75 admitted; 33.25 refused (gaps 16.75/16.5 regular); 50 admitted (gaps "
             "16.75/33.25 irregular) and the window is full. 1000 (0 has left, gaps 33.25/950), "
             "1016.75 (16.75 has left, gaps 950/16.75) admitted; 1033.25 refused (window full); "
             "1050 (50 has left, gaps 16.75/33.25) admitted. Admitted onsets are capped to 0.79, "
             "refused ones lowered to 0.4. Before the fix every frame came out at 0.79.",
             tight, frames, [0, 16.75, 50, 1000, 1016.75, 1050]),
        case("slow-ramp-through-threshold-60hz",
             "Onsets ramp from 0.5 by 1/120 per 60 Hz frame, reaching 0.8 at frame 36 (600 ms) "
             "and 1.0 at frame 60. Frames below 0.8 pass unchanged. 600 and 616.75 admitted; "
             "633.25 refused (regular); 650 admitted (gaps 16.75/33.25); later frames refused, "
             "the window staying full to the end at 1183.25 because 600 leaves only at 1600.",
             DEFAULT_POLICY, ramp, [600, 616.75, 650]),
        case("slow-ramp-through-threshold-cap-0.6",
             "The same ramp with the cap tightened to 0.6. Detection is on the pre-cap onset, so "
             "the same three flashes are admitted and capped to 0.6, refused flashes are 0.4, and "
             "onsets from 0.6 to 0.8 are capped to 0.6. Before the fix nothing was refused.",
             dict(DEFAULT_POLICY, maxLuminanceDelta=0.6), ramp, [600, 616.75, 650]),
    ]


JITTER = {
    60: (0, 1.5, -1.25, 0.75, -2, 1.25, -0.5, 2, -1.5, 0.25),
    120: (0, 0.75, -0.5, 1, -1, 0.25, -0.75, 0.5),
    144: (0, 0.5, -0.75, 0.25, -0.5, 0.75, -0.25),
}


def jitter_cases():
    derivations = {
        60: ("0 and 18.25 admitted; 32 refused (gaps 18.25/13.75 differ by 4.5, within 25% of "
             "18.25 = 4.5625); 50.75 admitted (gaps 18.25/32.5) and the window is full. 1000 "
             "admitted (0 is exactly 1000 ms old and has left; gaps 32.5/949.25); 1018.25 "
             "admitted (18.25 has left; gaps 949.25/18.25); 1032 refused (window full); 1050.75 "
             "admitted (50.75 has left; gaps 18.25/32.5); the rest refused.",
             [0, 18.25, 50.75, 1000, 1018.25, 1050.75]),
        120: ("0 and 9 admitted; 16.25 refused (gaps 9/7.25 differ by 1.75 <= 2.25); 26 admitted "
              "(gaps 9/17) and the window is full. 1000 admitted (0 has left; gaps 17/974); 1009 "
              "admitted (9 has left; gaps 974/9); 1016.25 refused (26 is 990.25 ms old, window "
              "full); 1026 admitted (26 has left; gaps 9/17); the rest refused.",
              [0, 9, 26, 1000, 1009, 1026]),
        144: ("0 and 7.5 admitted; 13.25 refused (gaps 7.5/5.75 differ by 1.75 <= 1.875); 21 "
              "admitted (gaps 7.5/13.5) and the window is full; 999.5 refused (0 is 999.5 ms "
              "old). 1007.75 admitted (0 and 7.5 have left, one flash in the window); 1013.75 "
              "admitted (gaps 986.75/6); 1020.75 refused (21 is 999.75 ms old, window full); "
              "1028.25 admitted (21 has left; gaps 6/14.5); the rest refused.",
              [0, 7.5, 21, 1007.75, 1013.75, 1028.25]),
    }
    cases = []
    for hz, (why, admitted) in derivations.items():
        frames = [full_flash(t) for t in grid(hz, 0, 1100, JITTER[hz])]
        cases.append(case(
            f"{hz}hz-jittered-every-frame-flash",
            f"Every {hz} Hz frame, its time jittered by up to {max(JITTER[hz])} ms, is a "
            f"full-screen flash; the default policy applies. " + why,
            DEFAULT_POLICY, frames, admitted))
    return cases


def periodic(rate_hz, frames_60hz):
    """A 60 Hz stream whose flashes fall on the frame nearest each period of `rate_hz`."""
    flash_frames = {round(k * 60 / rate_hz) for k in range(int(frames_60hz * rate_hz / 60) + 1)}
    return [full_flash(t) if i in flash_frames else frame(t)
            for i, t in enumerate(grid(60, 0, frames_60hz * 1000 / 60))]


def rate_cases():
    return [
        case("2.9hz-regular-flashes-60hz",
             "Full-screen flashes on the 60 Hz frame nearest each 2.9 Hz period (frames 0, 21, "
             "41, 62, 83, 103, 124, 145, 166), dark frames between. Input: at most 3 flashes in "
             "any window, but 0/350/683.25 is a regular triplet, so it exceeds. 0, 350 admitted; "
             "683.25 refused (gaps 350/333.25 regular); 1033.25 admitted (0 has left); 1383.25 "
             "admitted (350 has left); 1716.75 refused (regular); 2066.75 and 2416.75 admitted; "
             "2766.75 refused. The strobe ban leaves 2 flashes per window.",
             DEFAULT_POLICY, periodic(2.9, 168),
             [0, 350, 1033.25, 1383.25, 2066.75, 2416.75]),
        case("3.1hz-regular-flashes-60hz",
             "Flashes on the 60 Hz frame nearest each 3.1 Hz period (frames 0, 19, 39, 58, 77, "
             "97, 116, 135, 155). Input: 0/316.75/650/966.75 puts 4 flashes in one window. 0, "
             "316.75 admitted; 650 refused (gaps 316.75/333.25 regular); 966.75 admitted (gaps "
             "316.75/650 irregular, 3 in the window); 1283.25 admitted (0 has left; gaps "
             "650/316.5); 1616.75 refused (gaps 316.5/333.5 regular); 1933.25 admitted (gaps "
             "316.5/650); 2250 admitted (966.75 has left; gaps 650/316.75); 2583.25 refused. "
             "Output: exactly 3 flashes in several windows, never 4, no regular triplet.",
             DEFAULT_POLICY, periodic(3.1, 168),
             [0, 316.75, 966.75, 1283.25, 1933.25, 2250]),
    ]


def sub_threshold_ramp():
    frames = []
    for i, t in enumerate(grid(60, 0, 1100)):
        level = round(0.79 * (1 - abs(i - 33) / 33), 4)
        frames.append(frame(t, broadband=level, low=level, mid=round(level / 2, 4), area=1))
    return case("slow-ramp-sub-threshold-60hz",
                "Full-screen onsets ramp from 0 up to 0.79 at frame 33 (550 ms) and back down "
                "over 1.1 s at 60 Hz. No onset reaches 0.8 or the 0.8 cap, so there are no "
                "flashes and the output equals the input.",
                DEFAULT_POLICY, frames, [])


def mixed_case():
    general = dict(broadband=0.95, low=0.85, mid=0.9, high=0.6, area=1)
    red = dict(broadband=0.3, low=0.2, mid=0.3, high=0.1, red=1, area=1)
    both = dict(broadband=1, low=1, mid=0.5, high=0.9, red=1, area=1)
    small = dict(broadband=1, low=1, mid=1, high=1, red=1, area=0.2)
    pattern = {0: both, 6: red, 12: both, 15: small, 18: general, 30: both, 60: red, 61: general,
               66: both}
    frames = [frame(t, **pattern.get(i, {})) for i, t in enumerate(grid(60, 0, 1201))]
    return case("mixed-red-and-general-60hz",
                "60 Hz stream mixing general, red, combined and small-area frames; red budget 2. "
                "0 (both): general and red admitted, onsets capped to 0.8. 100 (red): red "
                "admitted. 200 (both): general admitted, red refused to 0.4 (budget 2 spent). "
                "250 (area 0.2): not a flash, onsets capped, red kept at 1. 300 (general): gaps "
                "200/100 irregular, admitted; general window full. 500 (both): general refused "
                "(4th in window) and red refused. 1000 (red): 0 has left the red window, red "
                "admitted. 1016.75 (general): 0 has left, gaps 100/716.75, admitted. 1100 "
                "(both): general refused (200/300/1016.75 in window), red admitted (100 has "
                "left). Input: 5 general flashes from 200 to 1100 and 4 red flashes in one "
                "window.",
                dict(DEFAULT_POLICY, maxRedFlashes=2), frames,
                [0, 200, 300, 1016.75], [0, 100, 1000, 1100])


def frame_rate_change_case():
    times = grid(60, 0, 400) + grid(144, 400, 800) + grid(30, 800, 1500) + grid(4, 1500, 2501)
    return case("frame-rate-change-60-144-30-4hz",
                "Every frame is a full-screen flash while the host changes rate mid-stream: 60 Hz "
                "to 400 ms, 144 Hz to 800 ms, 30 Hz to 1500 ms, then 4 Hz (250 ms gaps, still "
                "credited). 0, 16.75 admitted; 33.25 refused (regular); 50 admitted; every "
                "144 Hz and early 30 Hz frame refused (window full). 1000 admitted (0 has left; "
                "gaps 33.25/950); 1033.25 admitted (16.75 has left; gaps 950/33.25); 1066.75 "
                "refused (gaps 33.25/33.5 regular); 1100 admitted (gaps 33.25/66.75). 1500 and "
                "1750 refused (window full); 2000 admitted (1000 has left; gaps 66.75/900); 2250 "
                "admitted (1033.25 and 1100 have left); 2500 refused (gaps 250/250 regular).",
                DEFAULT_POLICY, [full_flash(t) for t in times],
                [0, 16.75, 50, 1000, 1033.25, 1100, 2000, 2250])


def main():
    cases = (cap_cases() + jitter_cases() + rate_cases()
             + [sub_threshold_ramp(), mixed_case(), frame_rate_change_case()])
    doc = {
        "description": "Real frame cadences and tightened caps. Each case's derivation states "
                       "how its admitted flashes were worked out by hand from the rules in this "
                       "directory's README; tools/limiter-cadence-vectors.py checks them against "
                       "an independent model of those rules and writes this file.",
        "tolerance": 0,
        "cases": cases,
    }
    sys.stdout.write(dump(doc))


def number(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)) and float(v).is_integer():
        return str(int(v))
    return repr(v)


def compact(obj):
    return "{" + ", ".join(f'"{k}": {number(obj[k])}' for k in FIELDS) + "}"


def dump(doc):
    lines = ["{", f'  "description": {json.dumps(doc["description"])},',
             f'  "tolerance": {doc["tolerance"]},', '  "cases": [']
    for ci, c in enumerate(doc["cases"]):
        lines.append("    {")
        keys = list(c)
        for ki, k in enumerate(keys):
            end = "," if ki < len(keys) - 1 else ""
            v = c[k]
            if k in ("input", "clamped"):
                lines.append(f'      "{k}": [')
                for fi, f in enumerate(v):
                    lines.append("        " + compact(f) + ("," if fi < len(v) - 1 else ""))
                lines.append("      ]" + end)
            elif isinstance(v, dict):
                body = ", ".join(f'"{kk}": {number(vv)}' for kk, vv in v.items())
                lines.append(f'      "{k}": {{{body}}}{end}')
            elif isinstance(v, str):
                lines.append(f'      "{k}": {json.dumps(v)}{end}')
            else:
                lines.append(f'      "{k}": {number(v)}{end}')
        lines.append("    }" + ("," if ci < len(doc["cases"]) - 1 else ""))
    lines += ["  ]", "}", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    main()
