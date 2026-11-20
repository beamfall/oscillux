#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Generate the frame-window governor vectors from a standard-library model."""

import argparse
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "conformance/window-governor/reference.json"
DEFAULTS = {
    "demote_budget_fraction": 0.85,
    "promote_budget_fraction": 0.60,
    "demote_windows": 30,
    "promote_windows": 300,
    "cooldown_s": 5.0,
}


def sample(now, p95=3.0, p99=7.0, interval=1000 / 60, budget=8.33, starved=False,
           dropping=False, can_demote=True):
    return [p95, p99, interval, budget, starved, dropping, now, can_demote]


def series(count, *, start=0, hz=60, **telemetry):
    return [sample(start + index / hz, **telemetry) for index in range(1, count + 1)]


def case(name, samples, *, start=0, config=None):
    rules = config if config is not None else DEFAULTS
    since_change = []
    change_at = start
    stable = 0
    steps = []
    for entry in samples:
        if isinstance(entry, dict):
            change_at = entry["reset_s"]
            since_change.clear()
            stable = 0
            steps.append(entry)
            continue
        p95, p99, interval, budget, starved, dropping, now, can_demote = entry
        classification = "neutral"
        if p95 is not None and p99 is not None:
            if (
                p95 > rules["demote_budget_fraction"] * interval
                or p99 > interval
                or starved
                or dropping
            ):
                classification = "over"
            elif p95 < rules["promote_budget_fraction"] * budget:
                classification = "eligible"
        since_change.append(classification)
        trailing = sum(
            1 for _ in itertools.takewhile(lambda item: item == classification, reversed(since_change))
        )
        over = trailing if classification == "over" else 0
        eligible = trailing if classification == "eligible" else 0
        if over >= rules["demote_windows"]:
            decision = "demote" if can_demote else "hold"
        elif eligible >= rules["promote_windows"] and now - change_at >= rules["cooldown_s"]:
            decision = "promote"
        else:
            decision = "hold"
        if decision != "hold":
            change_at = now
            since_change.clear()
            over = eligible = stable = 0
        elif over < rules["demote_windows"]:
            stable += 1
        steps.append({
            "sample": entry,
            "want": [decision, classification == "over", over, eligible, stable],
        })
    return {"name": name, "start_s": start, "config": config, "steps": steps}


def vectors():
    fast = {
        "demote_budget_fraction": 0.70,
        "promote_budget_fraction": 0.40,
        "demote_windows": 2,
        "promote_windows": 2,
        "cooldown_s": 2.0,
    }
    floor = {"interval": 1000 / 30, "budget": 1000 / 60, "can_demote": False}
    return [
        case("healthy-60hz-toward-120hz", series(301)),
        case("p99-only-overload", series(31, p99=17.0)),
        case("starved-delivery", series(30, starved=True)),
        case("dropping-delivery", series(30, dropping=True)),
        case("settled-at-floor-preserves-stability-and-cooldown",
             series(300, hz=120, p95=12, p99=18, **floor)
             + series(31, start=4, starved=True, **floor)
             + [sample(now, **floor) for now in (4.98, 4.99, 5.0)],
             config={**DEFAULTS, "promote_windows": 2}),
        case("cooldown-blocks-promotion", series(300, start=10, hz=120) + [
            sample(14.99), sample(15),
        ], start=10),
        case("missing-percentiles-hold-and-break-streaks", [
            sample(1, p99=20.0), sample(2, p95=None, p99=20.0, starved=True),
            sample(3, p99=20.0), sample(4), sample(5, p99=None, dropping=True),
            sample(6), sample(7),
        ], config=fast),
        case("reset-and-step-start-new-cooldowns", [
            sample(3, p99=12, budget=10), {"reset_s": 4},
            sample(4, p99=12, budget=10), sample(5, p99=12, budget=10),
            sample(6, p99=12, budget=10),
            sample(6, p99=20), sample(6, p99=20),
            sample(7, budget=10), sample(7, budget=10), sample(8, budget=10),
        ], config=fast),
        case("strict-thresholds-and-no-promotion-step", [
            sample(1, p95=14, p99=20, interval=20, budget=10),
            sample(2, p95=15, p99=20, interval=20, budget=10),
            sample(3, p95=15, p99=20, interval=20, budget=10),
            sample(4, p95=4, budget=10), sample(5, p95=5, budget=10),
            sample(6, budget=10), sample(7, p95=0, budget=0),
            sample(8, budget=10), sample(9, budget=10),
        ], config=fast),
    ]


def render(cases):
    lines = [
        "{",
        ' "SPDX-License-Identifier": "AGPL-3.0-only",',
        ' "format": "oscillux-window-governor-vectors/1",',
        ' "generator": "tools/window-governor-vectors.py",',
        ' "sample_fields": ["p95_ms","p99_ms","interval_ms","promotion_budget_ms","starved","dropping","now_s","can_demote"],',
        ' "result_fields": ["decision","over_budget","over_budget_streak","promotion_streak","stable_streak"],',
        ' "cases": [',
    ]
    for item in cases:
        lines.append("  {")
        for key in ("name", "start_s", "config"):
            lines.append(f"   {json.dumps(key)}: {json.dumps(item[key])},")
        lines.append('   "steps": [')
        lines.append(",\n".join("    " + json.dumps(step, separators=(",", ":")) for step in item["steps"]))
        lines.extend(("   ]", "  },"))
    lines[-1] = "  }"
    return "\n".join(lines + [" ]", "}", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check the committed vectors")
    args = parser.parse_args()
    generated = render(vectors())
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != generated:
            parser.exit(1, "window governor vectors differ. Run python3 -I tools/window-governor-vectors.py\n")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(generated, encoding="utf-8")


if __name__ == "__main__":
    main()
