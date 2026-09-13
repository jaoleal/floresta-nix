#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Turn a run's raw streams into the CSVs that are the harness's contract.

Raw in, tidy out.  The run phase writes only append-only streams --
proc.raw (target uptime stamps), power.raw (meter stamps), florestad.log
(the node's own local-time stamps) -- and this step puts all three on the
host's millisecond clock, which is the one clock every consumer can
trust.

Doing it here rather than during the run is deliberate.  A parser bug
found next month can be fixed and re-run against the stored raw files; a
parser bug that ate the data while it was being collected cannot.

Column names are a contract.  Changing one means bumping
schema_version in meta.json, so that a notebook written against an old
run keeps working or fails loudly.
"""

import csv
import hashlib
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA_VERSION = 1

PROC_COLUMNS = [
    "t_ms",
    "up_cs",
    "cpu_user_ms",
    "cpu_nice_ms",
    "cpu_sys_ms",
    "cpu_idle_ms",
    "cpu_iowait_ms",
    "cpu_irq_ms",
    "cpu_softirq_ms",
    "mem_available_kb",
    "mem_cached_kb",
    "mem_dirty_kb",
    "mem_writeback_kb",
    "swap_free_kb",
    "disk_reads",
    "disk_read_bytes",
    "disk_writes",
    "disk_write_bytes",
    "disk_io_ms",
    "net_rx_bytes",
    "net_tx_bytes",
    "proc_utime_ms",
    "proc_stime_ms",
    "proc_rss_kb",
    "proc_minflt",
    "proc_majflt",
    "proc_read_bytes",
    "proc_write_bytes",
    "temp_millicelsius",
    "throttled",
    "psi_cpu_avg10",
    "psi_io_avg10",
    "psi_mem_avg10",
    "florestad_alive",
    "collector_cpu_ms",
]

BLOCK_COLUMNS = [
    "t_ms",
    "height",
    "hash",
    "tx_count",
    "block_bytes",
    "block_weight",
    "inputs",
    "outputs",
    "proof_bytes",
    "proof_hashes",
    "utxos_added",
    "utxos_removed",
    "ms_download",
    "ms_validate",
    "ms_total",
]

POWER_COLUMNS = ["t_ms", "volts", "amps", "watts", "mah", "mwh"]

# florestad's own log lines, in the order the phases they mark occur.
# Anchored on literals from crates/floresta-{wire,chain,node}; if a
# release renames one, the affected window simply does not open, and
# build-report.py says the window is missing rather than inventing it.
WINDOW_MARKERS = [
    ("header_sync", "open", "Starting IBD, selecting the best chain"),
    ("header_sync", "close", "Finished downloading headers from peer"),
    ("tip_sync", "open", "Starting sync node"),
    ("tip_sync", "close", "IBD is finished, switching to normal operation mode"),
    ("backfill", "open", "Starting backfill task"),
    ("backfill", "open", "Recovering backfill node from state"),
    ("backfill", "close", "Backfilling task shutting down"),
    ("catch_up", "open", "Catching up with the network"),
]

LOG_LINE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,9})?)\s+"
    r"(?P<level>[A-Z]+)\s+(?P<target>[\w-]+):\s*(?P<msg>.*)$"
)
NEW_TIP = re.compile(
    r"New tip! hash=(?P<hash>[0-9a-f]+) height=(?P<height>\d+) tx_count=(?P<tx>\d+)"
)


def die(msg):
    print(f"assemble: {msg}", file=sys.stderr)
    raise SystemExit(1)


class Clock:
    """Every target-side timestamp, expressed on the host's clock.

    Two independent conversions live here:

    * uptime -> host, for proc.raw.  The anchor was measured by the
      harness at preflight; uptime cannot jump, which is the entire
      reason a board without an RTC is sampled this way.

    * local wall time -> host, for florestad's log.  tracing-subscriber
      formats in the target's local timezone, so the offset recorded at
      preflight is applied here, plus a linear drift correction when the
      clock moved more than a second between the run's two measurements.
    """

    def __init__(self, meta):
        clock = meta.get("clock", {})
        self.boot_epoch_ms = clock.get("boot_epoch_ms", 0)
        self.offset_start = clock.get("offset_start_ms", 0)
        self.offset_end = clock.get("offset_end_ms", 0)
        self.drift_ms = clock.get("drift_ms", 0)
        self.tz = self._parse_tz(meta.get("target", {}).get("tz", "+0000"))
        self.t0 = None
        self.t1 = None
        # The offset is always removed -- a systematic 1.5 s skew
        # between blocks.csv and proc.csv would misalign them even
        # though preflight tolerates it.  Whether the skew *moved*
        # during the run is the separate fact the report announces,
        # since below a second it is smaller than the resolution of the
        # measurement that produced it.
        self.drift_correction = abs(self.drift_ms) > 1000
        self.applied_correction = False

    @staticmethod
    def _parse_tz(spec):
        m = re.match(r"^([+-])(\d{2})(\d{2})$", (spec or "").strip())
        if not m:
            return timezone.utc
        sign = 1 if m.group(1) == "+" else -1
        return timezone(sign * timedelta(hours=int(m.group(2)), minutes=int(m.group(3))))

    def span(self, t0, t1):
        self.t0, self.t1 = t0, t1

    def _offset_at(self, t_ms):
        """The target's clock error at this instant, to be subtracted.

        Linear between the two measurements when the clock moved during
        the run; constant when it did not.
        """
        if not self.drift_correction or self.t0 is None or self.t1 is None or self.t1 <= self.t0:
            return -self.offset_start
        frac = max(0.0, min(1.0, (t_ms - self.t0) / (self.t1 - self.t0)))
        self.applied_correction = True
        return -(self.offset_start + frac * (self.offset_end - self.offset_start))

    def from_uptime_cs(self, up_cs):
        # Uptime is immune to the wall clock, so no drift term: the
        # anchor already expressed it on the host's clock.
        return int(self.boot_epoch_ms + up_cs * 10)

    def from_local(self, ts_text):
        fmt = "%Y-%m-%d %H:%M:%S.%f" if "." in ts_text else "%Y-%m-%d %H:%M:%S"
        naive = datetime.strptime(ts_text, fmt)
        t_ms = int(naive.replace(tzinfo=self.tz).timestamp() * 1000)
        return int(t_ms + self._offset_at(t_ms))


def assemble_proc(run_dir, clock):
    raw = run_dir / "proc.raw"
    out = run_dir / "proc.csv"
    rows = 0
    first = last = None
    with out.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(PROC_COLUMNS)
        if not raw.exists():
            return 0, None, None
        for line in raw.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            fields = line.split(",")
            # One short line means one truncated write, not a broken
            # run: drop it and keep going.
            if len(fields) != len(PROC_COLUMNS) - 1:
                continue
            try:
                up_cs = int(fields[0])
            except ValueError:
                continue
            t_ms = clock.from_uptime_cs(up_cs)
            first = t_ms if first is None else first
            last = t_ms
            writer.writerow([t_ms] + fields)
            rows += 1
    return rows, first, last


def assemble_blocks(run_dir, clock):
    """Block events, from the only source that has them: the log.

    What is NOT here matters as much as what is.  florestad's "New tip!"
    line carries the hash, the height and the transaction count, and
    that is all it carries.  Block size, weight, input/output counts,
    utreexo proof size, accumulator deltas, and -- most importantly --
    the split between time spent downloading and time spent validating
    are not emitted anywhere, so those columns stay empty rather than
    being estimated.  build-report.py says so out loud in the report.
    """
    log = run_dir / "florestad.log"
    out = run_dir / "blocks.csv"
    events = []
    if log.exists():
        prev_t = None
        for line in log.read_text(errors="replace").splitlines():
            m = LOG_LINE.match(line.strip())
            if not m:
                continue
            tip = NEW_TIP.search(m.group("msg"))
            if not tip:
                continue
            t_ms = clock.from_local(m.group("ts"))
            ms_total = "" if prev_t is None else t_ms - prev_t
            prev_t = t_ms
            events.append(
                {
                    "t_ms": t_ms,
                    "height": int(tip.group("height")),
                    "hash": tip.group("hash"),
                    "tx_count": int(tip.group("tx")),
                    "ms_total": ms_total,
                }
            )

    with out.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=BLOCK_COLUMNS, restval="")
        writer.writeheader()
        for event in events:
            writer.writerow(event)
    return events


def assemble_power(run_dir):
    """Meter samples, plus the accumulated charge and energy.

    The meter's own running totals are ignored on purpose: integrating
    here means the accumulators start at zero exactly when the run does,
    and cannot be thrown off by a meter that was left running yesterday.
    """
    raw = run_dir / "power.raw"
    out = run_dir / "power.csv"
    rows = 0
    # The contracted CSVs always exist, header and all, even when the run
    # had no meter: a file with zero rows says "measured nothing"
    # unambiguously, where a missing file could equally mean the harness
    # crashed before writing it.  Raw captures are the opposite -- absent
    # when nothing produced them.
    if not raw.exists() or raw.stat().st_size == 0:
        with out.open("w", newline="") as fh:
            csv.writer(fh).writerow(POWER_COLUMNS)
        return 0, None
    mah = mwh = 0.0
    prev_t = None
    stats = {"min_volts": None, "max_watts": None, "n": 0}
    with out.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(POWER_COLUMNS)
        for line in raw.read_text(errors="replace").splitlines():
            parts = line.strip().split(",")
            if len(parts) < 4:
                continue
            try:
                t_ms = int(parts[0])
                volts, amps, watts = (float(parts[1]), float(parts[2]), float(parts[3]))
            except ValueError:
                continue
            if prev_t is not None:
                hours = (t_ms - prev_t) / 3_600_000.0
                # A gap longer than a minute means the meter stopped
                # reporting; integrating across it would invent energy
                # that was never measured.
                if 0 <= hours <= 1.0 / 60:
                    mah += amps * 1000.0 * hours
                    mwh += watts * 1000.0 * hours
            prev_t = t_ms
            stats["n"] += 1
            if stats["min_volts"] is None or volts < stats["min_volts"]:
                stats["min_volts"] = volts
            if stats["max_watts"] is None or watts > stats["max_watts"]:
                stats["max_watts"] = watts
            writer.writerow(
                [t_ms, f"{volts:.4f}", f"{amps:.5f}", f"{watts:.4f}", f"{mah:.4f}", f"{mwh:.4f}"]
            )
            rows += 1
    return rows, stats


def assemble_windows(run_dir, clock, blocks):
    """Labelled intervals on the same clock as everything else.

    Without these a flamegraph or a CPU trace of the whole run is one
    smear of header sync, block sync and backfill.  With them, any
    series in the run can be sliced by phase, and two phases can be
    compared directly -- which is the comparison that actually explains
    a cost.
    """
    out = run_dir / "windows.csv"
    partial = run_dir / "windows.raw"
    rows = []

    if partial.exists():
        for line in partial.read_text().splitlines():
            parts = line.split(",")
            if len(parts) >= 2 and parts[1]:
                rows.append(
                    {
                        "label": parts[0],
                        "start_ms": int(float(parts[1])),
                        "end_ms": int(float(parts[2])) if len(parts) > 2 and parts[2] else "",
                        "source": "harness",
                    }
                )

    log = run_dir / "florestad.log"
    open_windows = {}
    if log.exists():
        for line in log.read_text(errors="replace").splitlines():
            m = LOG_LINE.match(line.strip())
            if not m:
                continue
            msg = m.group("msg")
            for label, action, marker in WINDOW_MARKERS:
                if marker not in msg:
                    continue
                t_ms = clock.from_local(m.group("ts"))
                if action == "open":
                    if label not in open_windows:
                        open_windows[label] = t_ms
                elif label in open_windows:
                    rows.append(
                        {
                            "label": label,
                            "start_ms": open_windows.pop(label),
                            "end_ms": t_ms,
                            "source": "florestad-log",
                        }
                    )
    # A phase that never ended (the run stopped inside it) is still a
    # phase; leaving end_ms empty says exactly that.
    for label, start in open_windows.items():
        rows.append(
            {"label": label, "start_ms": start, "end_ms": "", "source": "florestad-log"}
        )

    # The largest and smallest blocks of the run, so a differential
    # flamegraph has something to be differential about.
    sized = [b for b in blocks if b.get("ms_total") != ""]
    if len(sized) >= 4:
        by_tx = sorted(sized, key=lambda b: b["tx_count"])
        for block in (by_tx[0], by_tx[-1]):
            rows.append(
                {
                    "label": f"block:{block['height']}",
                    "start_ms": block["t_ms"] - int(block["ms_total"]),
                    "end_ms": block["t_ms"],
                    "source": "blocks",
                }
            )

    rows.sort(key=lambda r: r["start_ms"])
    with out.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["label", "start_ms", "end_ms", "source"])
        writer.writeheader()
        writer.writerows(rows)
    return rows


def write_manifest(run_dir, meta, counts):
    """Checksums for everything, so a run can be moved and still trusted."""
    artifacts = []
    for path in sorted(run_dir.iterdir()):
        if path.is_dir() or path.name == "manifest.json":
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        artifacts.append(
            {"name": path.name, "bytes": path.stat().st_size, "sha256": digest}
        )
    manifest = {
        "run_id": meta.get("run_id"),
        "schema_version": SCHEMA_VERSION,
        "run_kind": meta.get("run_kind"),
        "counts": counts,
        "columns": {
            "proc.csv": PROC_COLUMNS,
            "blocks.csv": BLOCK_COLUMNS,
            "power.csv": POWER_COLUMNS,
            "windows.csv": ["label", "start_ms", "end_ms", "source"],
        },
        "artifacts": artifacts,
    }
    (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    if len(sys.argv) != 2:
        die("usage: assemble.py <run-dir>")
    run_dir = Path(sys.argv[1])
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        die(f"no meta.json in {run_dir}")
    meta = json.loads(meta_path.read_text())

    clock = Clock(meta)
    proc_rows, first_ms, last_ms = assemble_proc(run_dir, clock)
    if first_ms and last_ms:
        clock.span(first_ms, last_ms)

    blocks = assemble_blocks(run_dir, clock)
    power_rows, power_stats = assemble_power(run_dir)
    windows = assemble_windows(run_dir, clock, blocks)

    counts = {
        "proc_rows": proc_rows,
        "block_events": len(blocks),
        "power_samples": power_rows,
        "windows": len(windows),
        "metric_scrapes": sum(
            1 for _ in (run_dir / "metrics.jsonl").open()
        )
        if (run_dir / "metrics.jsonl").exists()
        else 0,
    }

    # Facts the report needs but only this step can know.
    meta.setdefault("assembled", {})
    meta["assembled"] = {
        "counts": counts,
        "drift_correction_applied": clock.applied_correction,
        "power": power_stats or {},
    }
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")

    write_manifest(run_dir, meta, counts)

    print(
        f"assemble: {proc_rows} proc rows, {len(blocks)} block events, "
        f"{power_rows} power samples, {len(windows)} windows",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
