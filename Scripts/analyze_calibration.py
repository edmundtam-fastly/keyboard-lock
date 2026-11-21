#!/usr/bin/env python3
"""Turn a calibration recording into threshold recommendations.

The calibration log holds only timing/count measurements — never key
identities — so this reads how *close* normal typing came to each auto-lock
rule, and where a threshold could sit to clear it.

Usage:
    ./Scripts/analyze_calibration.py [path/to/calibration.csv]
"""
import csv
import sys
from collections import Counter
from pathlib import Path

DEFAULT = Path.home() / "Library/Application Support/KeyboardLock/calibration.csv"

# Must mirror LockLogic.swift.
THRESHOLDS = {
    "concurrentHeldThreshold": 4,
    "sustainedHeldCountIgnoringArrival": 3,
    "sustainedHeldCount": 2,
    "sustainedHeldDuration_ms": 1500,
    "sustainedCoArrivalWindow_ms": 120,
    "burstKeyCount": 8,
    "burstDistinctKeys": 5,
}


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[idx]


def describe(name, values, unit=""):
    if not values:
        print(f"  {name:<22} (no samples)")
        return
    print(
        f"  {name:<22} max {max(values):>6}{unit}   "
        f"p99.9 {percentile(values, 99.9):>6}{unit}   "
        f"p99 {percentile(values, 99):>6}{unit}   "
        f"median {percentile(values, 50):>6}{unit}"
    )


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not path.exists():
        sys.exit(f"No calibration file at {path}\nTurn on 'Record Calibration Data' in the menu first.")

    rows = list(csv.DictReader(path.open()))
    if not rows:
        sys.exit("Calibration file is empty.")

    # Rows after a "mark-cat" marker and before the next 30s of quiet are
    # treated as cat samples; everything else is human baseline.
    cat_windows = [float(r["t"]) for r in rows if r["kind"] == "mark-cat"]

    def is_cat(t):
        return any(abs(t - mark) <= 30.0 for mark in cat_windows)

    human = [r for r in rows if r["kind"] in ("down", "up", "poll") and not is_cat(float(r["t"]))]
    cat = [r for r in rows if r["kind"] in ("down", "up", "poll") and is_cat(float(r["t"]))]

    def ints(sample, field):
        return [int(r[field]) for r in sample if r[field] not in ("", None)]

    duration = max(float(r["t"]) for r in rows) if rows else 0
    print(f"\nFile: {path}")
    print(f"Samples: {len(rows)}  ({len(human)} human, {len(cat)} cat-marked)  over {duration/60:.1f} min\n")

    print("HUMAN TYPING — how far each rule's inputs actually got:")
    describe("keys held at once", ints(human, "held"))
    describe("arrival spread", ints(human, "held_spread_ms"), "ms")
    describe("longest hold", ints(human, "max_hold_ms"), "ms")
    describe("pinned (>=1.5s) keys", ints(human, "pinned"))
    describe("keydowns in 0.3s", ints(human, "win_downs"))
    describe("distinct in 0.3s", ints(human, "win_distinct"))

    fired = Counter(r["trigger"].split(":")[0] for r in human if r["trigger"])
    print()
    if fired:
        print("  !! Rules that WOULD have locked during normal typing:")
        for rule, count in fired.most_common():
            print(f"       {rule}: {count} time(s)")
    else:
        print("  No rule fired during human typing in this sample.")

    if cat:
        print("\nCAT-MARKED STRETCHES:")
        describe("keys held at once", ints(cat, "held"))
        describe("arrival spread", ints(cat, "held_spread_ms"), "ms")
        describe("longest hold", ints(cat, "max_hold_ms"), "ms")
        describe("pinned (>=1.5s) keys", ints(cat, "pinned"))

    print("\nRECOMMENDATIONS")
    held = ints(human, "held")
    peak_held = max(held) if held else 0
    if peak_held >= THRESHOLDS["concurrentHeldThreshold"]:
        # Spread separates rollover typing from a paw landing.
        tight = [
            int(r["held_spread_ms"])
            for r in human
            if int(r["held"]) >= THRESHOLDS["concurrentHeldThreshold"]
        ]
        print(
            f"  paw-landing: your typing reached {peak_held} concurrent keys "
            f"(threshold {THRESHOLDS['concurrentHeldThreshold']})."
        )
        if tight:
            print(
                f"    Those moments had an arrival spread of {min(tight)}–{max(tight)}ms. "
                "A paw lands inside ~50ms, so adding a co-arrival requirement to this\n"
                "    rule would separate them without raising the key count."
            )
        print(f"    Alternative: raise concurrentHeldThreshold to {peak_held + 1}.")
    else:
        print(
            f"  paw-landing: safe — peak {peak_held} concurrent vs threshold "
            f"{THRESHOLDS['concurrentHeldThreshold']}."
        )

    downs = ints(human, "win_downs")
    distinct = ints(human, "win_distinct")
    peak_downs, peak_distinct = (max(downs) if downs else 0), (max(distinct) if distinct else 0)
    if peak_downs >= THRESHOLDS["burstKeyCount"] and peak_distinct >= THRESHOLDS["burstDistinctKeys"]:
        print(f"  violent-mash: reached {peak_downs} downs / {peak_distinct} distinct — raise burstKeyCount to {peak_downs + 2}.")
    else:
        print(f"  violent-mash: safe — peak {peak_downs} downs / {peak_distinct} distinct.")

    pinned = ints(human, "pinned")
    peak_pinned = max(pinned) if pinned else 0
    if peak_pinned >= THRESHOLDS["sustainedHeldCount"]:
        print(f"  cat-sitting: reached {peak_pinned} pinned keys — check whether those were deliberate holds.")
    else:
        print(f"  cat-sitting: safe — peak {peak_pinned} pinned keys.")
    print()


if __name__ == "__main__":
    main()
