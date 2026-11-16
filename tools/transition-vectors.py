#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Write conformance/transition/reference.json from an independent model of the transition
scheduler.

The model below is written from conformance/transition/README.md and the transition section of
ffi/include/oscillux.h, using only + - * /, math.ceil, comparisons and the smoothstep
polynomial, in the same operation order the specification gives. Python floats are IEEE
binary64, so the expected values are exact: the Rust core, the C interface, the web port
(hosts/web/transition.js) and the Swift port (hosts/apple/Sources/TransitionDirector.swift)
must reproduce them bit for bit. Rust output is never used.

Non-finite inputs are written as the strings "NaN", "Infinity" and "-Infinity".

Usage: python3 -I tools/transition-vectors.py
       python3 -I tools/transition-vectors.py --check   (exit 1 if reference.json would change)
"""

import json
import math
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REFERENCE = os.path.join(ROOT, "conformance", "transition", "reference.json")

NONE, BEAT, BAR = 0, 1, 2
IDLE, PRE_ROLL, WAITING, BLENDING, DONE = 0, 1, 2, 3, 4
LINEAR, SMOOTHSTEP = 0, 1
MIN_DURATION, MAX_DURATION = 0.8, 2.5
MIN_TEMPO, MAX_TEMPO = 30.0, 300.0
FALLBACK_TEMPO = 120.0

DEFAULT = {
    "easing": LINEAR,
    "beats_per_bar": 4,
    "auto_advance_bars": 0,
    "duration_beats": 4.0,
    "fallback_seconds": 1.6,
    "pre_roll_seconds": 0.5,
    "min_confidence": 0.5,
}


class Refused(Exception):
    pass


def valid_config(c):
    return (
        c["easing"] in (LINEAR, SMOOTHSTEP)
        and 1 <= c["beats_per_bar"] <= 16
        and 0 <= c["auto_advance_bars"] <= 1024
        and 0.0 < c["duration_beats"] <= 64.0
        and MIN_DURATION <= c["fallback_seconds"] <= MAX_DURATION
        and 0.0 <= c["pre_roll_seconds"] <= 10.0
        and 0.0 <= c["min_confidence"] <= 1.0
    )


def beat_seconds(c, clock):
    """Beat period when the clock is confident, else None."""
    t, beat_phase, bar_phase, tempo, confidence = clock
    if (
        confidence >= c["min_confidence"]
        and MIN_TEMPO <= tempo <= MAX_TEMPO
        and 0.0 <= beat_phase <= 1.0
        and 0.0 <= bar_phase <= 1.0
    ):
        return 60.0 / tempo
    return None


def boundary(request, earliest, phase, period):
    k = float(math.ceil((earliest - request) / period + phase))
    at = request + (k - phase) * period
    return earliest if at < earliest else at


class Model:
    def __init__(self, config):
        if not valid_config(config):
            raise Refused()
        self.c = config
        self.schedule = None  # (request, earliest, start, end, quantise)
        self.anchor = None

    def reset(self):
        self.schedule = None
        self.anchor = None

    def request(self, clock, quantise, max_wait):
        t = clock[0]
        if not math.isfinite(t) or quantise not in (NONE, BEAT, BAR) or not max_wait >= 0.0:
            raise Refused()
        c = self.c
        earliest = t + c["pre_roll_seconds"]
        beat = beat_seconds(c, clock)
        if beat is None:
            start, applied, duration = earliest, NONE, c["fallback_seconds"]
        else:
            start, applied = earliest, NONE
            if quantise == BAR:
                at = boundary(t, earliest, clock[2], beat * float(c["beats_per_bar"]))
                if at - earliest <= max_wait:
                    start, applied = at, BAR
            if quantise != NONE and applied == NONE:
                at = boundary(t, earliest, clock[1], beat)
                if at - earliest <= max_wait:
                    start, applied = at, BEAT
            duration = min(max(c["duration_beats"] * beat, MIN_DURATION), MAX_DURATION)
        self.schedule = (t, earliest, start, start + duration, applied)
        self.anchor = None
        return self.status(t, 0)

    def progress(self, t):
        if self.schedule is None:
            return 0.0
        _, _, start, end, _ = self.schedule
        if not t > start:
            return 0.0
        if t >= end:
            return 1.0
        u = min(max((t - start) / (end - start), 0.0), 1.0)
        return u * u * (3.0 - 2.0 * u) if self.c["easing"] == SMOOTHSTEP else u

    def update(self, clock):
        t = clock[0]
        if not math.isfinite(t):
            raise Refused()
        c = self.c
        if c["auto_advance_bars"] > 0:
            settled = self.schedule is None or t >= self.schedule[3]
            if settled:
                if self.anchor is None:
                    self.anchor = t if self.schedule is None else self.schedule[3]
                beat = beat_seconds(c, clock)
                bar = (60.0 / FALLBACK_TEMPO if beat is None else beat) * float(c["beats_per_bar"])
                if t - self.anchor >= float(c["auto_advance_bars"]) * bar:
                    self.request(clock, BAR, bar)
                    return self.status(t, 1)
        return self.status(t, 0)

    def status(self, t, auto):
        if self.schedule is None:
            return [0.0, 0.0, 0.0, 0.0, IDLE, NONE, auto]
        request, earliest, start, end, applied = self.schedule
        if t >= end:
            state = DONE
        elif t >= start:
            state = BLENDING
        elif t >= earliest:
            state = WAITING
        else:
            state = PRE_ROLL
        return [self.progress(t), request, start, end, state, applied, auto]


def enc(x):
    if isinstance(x, float) and not math.isfinite(x):
        return "NaN" if x != x else ("Infinity" if x > 0 else "-Infinity")
    return x


def run(name, config, ops, note=""):
    """ops: ("request", clock, quantise, max_wait) | ("update", clock) | ("status", t)
    | ("reset",). A clock is (time, beat_phase, bar_phase, tempo, confidence)."""
    case = {"name": name, "config": dict(config)}
    if note:
        case["note"] = note
    try:
        model = Model(config)
    except Refused:
        case["create"] = "refused"
        return case
    steps = []
    for op in ops:
        step = {"op": op[0]}
        try:
            if op[0] == "request":
                step["clock"] = [enc(v) for v in op[1]]
                step["quantise"] = op[2]
                step["max_wait"] = enc(op[3])
                step["want"] = model.request(op[1], op[2], op[3])
            elif op[0] == "update":
                step["clock"] = [enc(v) for v in op[1]]
                step["want"] = model.update(op[1])
            elif op[0] == "status":
                step["time"] = enc(op[1])
                step["want"] = model.status(op[1], 0)
            else:
                model.reset()
        except Refused:
            step["want"] = "refused"
        steps.append(step)
    case["steps"] = steps
    return case


def cfg(**kw):
    c = dict(DEFAULT)
    c.update(kw)
    return c


def frames(t0, t1, hz):
    n = 0
    while True:
        t = t0 + n / hz
        if t > t1:
            return
        yield t
        n += 1


def frac(x):
    return x - math.floor(x)


def live_clock(t, tempo, beats_per_bar=4, confidence=0.9, offset=0.0):
    """A steady beat clock: beat 0 at `offset` seconds."""
    beats = (t - offset) * tempo / 60.0
    return (t, frac(beats), frac(beats / beats_per_bar), tempo, confidence)


def cases():
    out = []
    nobeat = lambda t: (t, 0.0, 0.0, 0.0, 0.0)

    # Frame-rate independence: the same no-beat switch sampled at 30, 60 and 120 Hz.
    for hz in (30.0, 60.0, 120.0):
        ops = [("request", nobeat(3.0), BAR, 2.0)]
        ops += [("update", nobeat(t)) for t in frames(3.0, 5.4, hz)]
        out.append(run("no-beat-%dhz" % hz, DEFAULT, ops))

    # Quantised starts at 120 BPM (beat 0.5 s, bar 2 s) for bar, beat and none, several phases.
    for q, qname in ((BAR, "bar"), (BEAT, "beat"), (NONE, "none")):
        ops = []
        for bar_phase in (0.0, 0.1, 0.25, 0.5, 0.74, 0.75, 0.9, 0.999):
            beat_phase = frac(bar_phase * 4.0)
            clock = (10.0, beat_phase, bar_phase, 120.0, 0.9)
            ops.append(("request", clock, q, 2.0))
            for t in (10.0, 10.25, 10.5, 10.75, 11.0, 11.5, 12.0, 12.5, 13.0, 14.0, 15.0):
                ops.append(("status", t))
        out.append(run("quantise-%s-120bpm" % qname, DEFAULT, ops))

    # Wait limits: bar falls back to beat, beat to none.
    ops = []
    clock = (10.0, 0.6, 0.9, 120.0, 0.9)
    for wait in (2.0, 1.7, 1.69, 0.3, 0.2, 0.19, 0.0, float("inf")):
        ops.append(("request", clock, BAR, wait))
        ops.append(("request", clock, BEAT, wait))
    out.append(run("wait-limit-fallback", DEFAULT, ops))

    # Duration clamp across tempi, and a 96 BPM bar (4 beats = 2.5 s exactly).
    ops = []
    for tempo in (30.0, 60.0, 90.0, 96.0, 100.0, 128.0, 174.0, 240.0, 300.0):
        ops.append(("request", (0.0, 0.0, 0.0, tempo, 1.0), BAR, 10.0))
    out.append(run("duration-clamp", DEFAULT, ops))

    # No confident beat: low confidence, tempo out of range, phases out of range, NaN fields.
    ops = []
    for clock in (
        (1.0, 0.2, 0.2, 120.0, 0.49),
        (1.0, 0.2, 0.2, 29.9, 1.0),
        (1.0, 0.2, 0.2, 300.1, 1.0),
        (1.0, -0.01, 0.2, 120.0, 1.0),
        (1.0, 0.2, 1.01, 120.0, 1.0),
        (1.0, float("nan"), 0.2, 120.0, 1.0),
        (1.0, 0.2, 0.2, float("inf"), 1.0),
        (1.0, 0.2, 0.2, 120.0, float("nan")),
        (1.0, 0.2, 0.2, 120.0, 0.5),
        (1.0, 1.0, 1.0, 120.0, 1.0),
    ):
        ops.append(("request", clock, BAR, 2.0))
        ops.append(("status", 1.5))
    out.append(run("confidence-and-ranges", DEFAULT, ops))

    # Smoothstep easing and no pre-roll, on a beat clock sampled at 60 Hz.
    c = cfg(easing=SMOOTHSTEP, pre_roll_seconds=0.0, duration_beats=2.0)
    ops = [("request", live_clock(5.0, 128.0), BEAT, 1.0)]
    ops += [("update", live_clock(t, 128.0)) for t in frames(5.0, 6.6, 60.0)]
    out.append(run("smoothstep-beat-128bpm", c, ops))

    # Exactly on a boundary with no pre-roll starts at once.
    c = cfg(pre_roll_seconds=0.0)
    ops = [("request", (2.0, 0.0, 0.0, 120.0, 1.0), BAR, 2.0), ("status", 2.0), ("status", 4.0)]
    out.append(run("on-boundary-no-pre-roll", c, ops))

    # A request while blending replaces the schedule; reset returns to idle.
    ops = [
        ("request", nobeat(0.0), NONE, 0.0),
        ("status", 1.0),
        ("request", nobeat(1.0), NONE, 0.0),
        ("status", 1.0),
        ("status", 3.1),
        ("reset",),
        ("status", 3.1),
    ]
    out.append(run("replace-and-reset", DEFAULT, ops))

    # Auto-advance every 2 bars: without a beat (counted at 120 BPM) at 30 Hz, and on a
    # 100 BPM clock at 30 Hz, quantised to the bar.
    ops = [("update", nobeat(t)) for t in frames(0.0, 14.0, 30.0)]
    out.append(run("auto-advance-no-beat", cfg(auto_advance_bars=2), ops))
    ops = [("update", live_clock(t, 100.0, offset=0.13)) for t in frames(0.0, 16.0, 30.0)]
    out.append(run("auto-advance-100bpm", cfg(auto_advance_bars=2), ops))
    # A manual request restarts the auto-advance count from its own end.
    ops = [("update", nobeat(0.0)), ("request", nobeat(2.0), NONE, 0.0)]
    ops += [("update", nobeat(t)) for t in (2.0, 4.0, 4.1, 8.0, 8.09, 8.1, 8.2)]
    out.append(run("auto-advance-after-manual", cfg(auto_advance_bars=2), ops))

    # Refused inputs leave the schedule unchanged.
    ops = [
        ("request", nobeat(0.0), NONE, 0.0),
        ("request", nobeat(0.5), 3, 1.0),
        ("request", nobeat(0.5), BAR, float("nan")),
        ("request", nobeat(0.5), BAR, -1.0),
        ("request", (float("inf"), 0.0, 0.0, 120.0, 1.0), BAR, 1.0),
        ("update", (float("nan"), 0.0, 0.0, 0.0, 0.0)),
        ("status", 1.0),
    ]
    out.append(run("refused-inputs", DEFAULT, ops))

    # Refused configurations.
    for name, kw in (
        ("easing-2", {"easing": 2}),
        ("beats-per-bar-0", {"beats_per_bar": 0}),
        ("beats-per-bar-17", {"beats_per_bar": 17}),
        ("auto-advance-1025", {"auto_advance_bars": 1025}),
        ("duration-beats-0", {"duration_beats": 0.0}),
        ("duration-beats-nan", {"duration_beats": float("nan")}),
        ("fallback-below", {"fallback_seconds": 0.79}),
        ("fallback-above", {"fallback_seconds": 2.51}),
        ("pre-roll-negative", {"pre_roll_seconds": -0.01}),
        ("pre-roll-above", {"pre_roll_seconds": 10.01}),
        ("confidence-above", {"min_confidence": 1.01}),
    ):
        c = run("config-" + name, cfg(**kw), [])
        c["config"] = {k: enc(v) for k, v in c["config"].items()}
        out.append(c)
    return out


def document():
    return {
        "format": "oscillux-transition-vectors/1",
        "generator": "tools/transition-vectors.py",
        "tolerance": 0,
        "status_fields": [
            "progress",
            "request_seconds",
            "start_seconds",
            "end_seconds",
            "state",
            "quantise",
            "auto_requested",
        ],
        "clock_fields": ["time_seconds", "beat_phase", "bar_phase", "tempo_bpm", "confidence"],
        "cases": cases(),
    }


def render():
    """One case header per line and one step per line, so diffs stay readable."""
    doc = document()
    dump = lambda v: json.dumps(v, allow_nan=False, separators=(",", ":"))
    head = {k: v for k, v in doc.items() if k != "cases"}
    lines = ["{"]
    for k, v in head.items():
        lines.append(" %s:%s," % (dump(k), dump(v)))
    lines.append(' "cases":[')
    for i, case in enumerate(doc["cases"]):
        members = []
        for k, v in case.items():
            if k == "steps":
                rows = ",\n".join("    " + dump(step) for step in v)
                members.append('   "steps":[\n' + rows + "\n   ]" if v else '   "steps":[]')
            else:
                members.append("   %s:%s" % (dump(k), dump(v)))
        lines.append("  {")
        lines.append(",\n".join(members))
        lines.append("  }" + ("," if i + 1 < len(doc["cases"]) else ""))
    lines.append(" ]")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    assert json.loads(text) == json.loads(dump(doc))
    return text


def main():
    text = render()
    if "--check" in sys.argv[1:]:
        try:
            with open(REFERENCE, encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = None
        if current != text:
            print("conformance/transition/reference.json is stale; run tools/transition-vectors.py")
            return 1
        print("conformance/transition/: reference.json matches the oracle")
        return 0
    os.makedirs(os.path.dirname(REFERENCE), exist_ok=True)
    with open(REFERENCE, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote conformance/transition/reference.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
