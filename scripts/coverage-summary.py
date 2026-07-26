#!/usr/bin/env python3
"""Summarise an xcresult coverage report as Markdown.

Usage: coverage-summary.py <coverage.json> [--fail-under-watched N]

Reads the JSON produced by `xcrun xccov view --report --json` and prints a
Markdown summary suitable for a GitHub step summary.

The watched list is the cross-process surface: files where a regression is
invisible until it reaches a physical device, because the failure is a
disagreement between the app and the keyboard extension rather than a crash.
"""

import argparse
import json
import sys

WATCHED = [
    "KeyboardController.swift",
    "KeyboardDiagnosticsLog.swift",
    "RecordingSessionCapabilities.swift",
    "DictationModels.swift",
    "SharedStore.swift",
    "VoiceNoteTimeline.swift",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report")
    parser.add_argument(
        "--fail-under-watched",
        type=float,
        default=None,
        help="Exit non-zero if any watched file falls below this percentage.",
    )
    args = parser.parse_args()

    with open(args.report) as handle:
        report = json.load(handle)

    print("## Code coverage\n")
    print("| Target | Coverage |")
    print("|---|---:|")
    for target in report.get("targets", []):
        print(f"| {target['name']} | {target['lineCoverage'] * 100:.1f}% |")

    # A file can appear under more than one target; keep the best-covered copy,
    # since the keyboard sources are compiled into the test bundle as well.
    best: dict[str, dict] = {}
    for target in report.get("targets", []):
        for entry in target.get("files", []):
            name = entry["name"]
            if name not in WATCHED:
                continue
            if name not in best or entry["lineCoverage"] > best[name]["lineCoverage"]:
                best[name] = entry

    print("\n### Watched files\n")
    print("| File | Coverage | Lines |")
    print("|---|---:|---:|")
    for name in WATCHED:
        entry = best.get(name)
        if entry is None:
            print(f"| {name} | _not reported_ | — |")
            continue
        percent = entry["lineCoverage"] * 100
        print(f"| {name} | {percent:.1f}% | {entry['coveredLines']}/{entry['executableLines']} |")

    if args.fail_under_watched is None:
        return 0

    below = [
        (name, best[name]["lineCoverage"] * 100)
        for name in WATCHED
        if name in best and best[name]["lineCoverage"] * 100 < args.fail_under_watched
    ]
    if below:
        print(f"\n**Below the {args.fail_under_watched:.0f}% floor:**\n")
        for name, percent in below:
            print(f"- {name}: {percent:.1f}%")
        for name, percent in below:
            print(f"{name} at {percent:.1f}% is below the floor", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
