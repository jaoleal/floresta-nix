#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Cut folded stacks into the run's labelled windows.

A flamegraph of a whole run is header sync, block sync and backfill
averaged into one shape that describes none of them.  The point of
recording windows on a shared clock is that the same samples can be
re-cut afterwards: tip_sync against backfill, a 1000-tx block against a
30-tx one.

Input is `profile/folded-timed.txt`, one sample per line:

    <monotonic seconds> <folded;stack>

perf's timestamps are CLOCK_MONOTONIC, which is the same base as
/proc/uptime -- which is why the harness anchors uptime to the host
clock in the first place.
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path


def main():
    run_dir = Path(sys.argv[1])
    profile_dir = run_dir / "profile"
    timed = profile_dir / "folded-timed.txt"
    if not timed.exists():
        raise SystemExit("slice-profile: no folded-timed.txt")

    meta = json.loads((run_dir / "meta.json").read_text())
    boot_epoch_ms = meta["clock"]["boot_epoch_ms"]

    samples = []
    for line in timed.read_text(errors="replace").splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        try:
            monotonic_s = float(parts[0])
        except ValueError:
            continue
        samples.append((boot_epoch_ms + monotonic_s * 1000.0, parts[1]))

    if not samples:
        raise SystemExit("slice-profile: no parseable samples")

    def write_folded(path, stacks):
        counts = Counter(stacks)
        with path.open("w") as fh:
            for stack, count in sorted(counts.items()):
                fh.write(f"{stack} {count}\n")
        return sum(counts.values()), len(counts)

    total, unique = write_folded(profile_dir / "folded.txt", [s for _, s in samples])

    # An 'unknown' frame is a frame the report cannot attribute; above a
    # few percent the flamegraph is decoration.
    unknown = sum(
        1 for _, stack in samples if re.search(r"\[unknown\]|\bunknown\b", stack)
    )
    quality = {
        "samples": total,
        "unique_stacks": unique,
        "unknown_frames": unknown,
        "unknown_pct": round(100.0 * unknown / total, 2) if total else 0.0,
    }

    windows = []
    windows_csv = run_dir / "windows.csv"
    if windows_csv.exists():
        import csv

        with windows_csv.open() as fh:
            for row in csv.DictReader(fh):
                if row.get("end_ms"):
                    windows.append(
                        (row["label"], int(row["start_ms"]), int(row["end_ms"]))
                    )

    sliced = {}
    for label, start, end in windows:
        stacks = [s for t, s in samples if start <= t <= end]
        if not stacks:
            continue
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", label)
        count, _ = write_folded(profile_dir / f"folded-{safe}.txt", stacks)
        sliced[label] = count

    quality["windows"] = sliced
    (profile_dir / "quality.json").write_text(json.dumps(quality, indent=2) + "\n")

    print(
        f"slice-profile: {total} samples, {quality['unknown_pct']}% unknown "
        f"frames, {len(sliced)} window slices",
        file=sys.stderr,
    )
    if quality["unknown_pct"] > 10:
        print(
            "slice-profile: WARNING more than 10% of frames are unresolved; "
            "rebuild florestad with debug=1 and -C force-frame-pointers=yes",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
