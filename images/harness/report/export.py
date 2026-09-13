#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Convert a run into a format a notebook can open.

The CSVs are the contract, but nobody wants to re-parse a Prometheus
exposition by hand six months from now.  This flattens everything --
including the metrics that were stored raw -- into one queryable file.

    bench-node export --format sqlite  runs/2026…/
    bench-node export --format parquet runs/2026…/
"""

import argparse
import csv
import json
import sqlite3
import sys
from pathlib import Path

TABLES = ("blocks", "proc", "power", "windows")

# One Prometheus exposition line: name{labels} value.  Comments and
# blank lines are skipped by the caller.
def parse_exposition(body):
    rows = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "{" in line:
            name, rest = line.split("{", 1)
            labels, _, value = rest.rpartition("}")
            value = value.strip()
        else:
            parts = line.rsplit(None, 1)
            if len(parts) != 2:
                continue
            name, value = parts
            labels = ""
        try:
            rows.append((name.strip(), labels, float(value)))
        except ValueError:
            continue
    return rows


def load_metrics(run_dir):
    path = run_dir / "metrics.jsonl"
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        try:
            scrape = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not scrape.get("ok"):
            continue
        for name, labels, value in parse_exposition(scrape.get("body", "")):
            out.append(
                {
                    "t_ms": scrape["t_ms"],
                    "name": name,
                    "labels": labels,
                    "value": value,
                }
            )
    return out


def read_csv(path):
    if not path.exists():
        return [], []
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
        return reader.fieldnames or [], rows


def maybe_number(value):
    if value == "" or value is None:
        return None
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        return value


def export_sqlite(run_dir, out_path):
    conn = sqlite3.connect(out_path)
    conn.execute("CREATE TABLE meta (json TEXT)")
    conn.execute(
        "INSERT INTO meta VALUES (?)", ((run_dir / "meta.json").read_text(),)
    )
    for table in TABLES:
        columns, rows = read_csv(run_dir / f"{table}.csv")
        if not columns:
            continue
        quoted = ", ".join(f'"{c}"' for c in columns)
        conn.execute(f"CREATE TABLE {table} ({quoted})")
        placeholders = ", ".join("?" for _ in columns)
        conn.executemany(
            f"INSERT INTO {table} VALUES ({placeholders})",
            [[maybe_number(row.get(c)) for c in columns] for row in rows],
        )
    metrics = load_metrics(run_dir)
    conn.execute("CREATE TABLE metrics (t_ms INTEGER, name TEXT, labels TEXT, value REAL)")
    conn.executemany(
        "INSERT INTO metrics VALUES (?,?,?,?)",
        [(m["t_ms"], m["name"], m["labels"], m["value"]) for m in metrics],
    )
    # The queries this file exists to make easy.
    conn.execute("CREATE INDEX idx_blocks_t ON blocks(t_ms)")
    conn.execute("CREATE INDEX idx_proc_t ON proc(t_ms)")
    conn.execute("CREATE INDEX idx_metrics ON metrics(name, t_ms)")
    conn.commit()
    conn.close()
    return len(metrics)


def export_parquet(run_dir, out_dir):
    try:
        import pyarrow  # noqa: F401
        import pyarrow.parquet as pq
        from pyarrow import csv as pacsv
    except ImportError:
        print(
            "export: parquet needs pyarrow, which is not in this environment.\n"
            "        Use --format sqlite, which is stdlib and holds the same\n"
            "        data including the parsed metrics.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for table in TABLES:
        source = run_dir / f"{table}.csv"
        if not source.exists():
            continue
        pq.write_table(pacsv.read_csv(source), out_dir / f"{table}.parquet")
        written.append(table)

    metrics = load_metrics(run_dir)
    if metrics:
        table = pyarrow.Table.from_pylist(metrics)
        pq.write_table(table, out_dir / "metrics.parquet")
        written.append("metrics")
    (out_dir / "meta.json").write_text((run_dir / "meta.json").read_text())
    return written


def main():
    parser = argparse.ArgumentParser(prog="bench-node export")
    parser.add_argument("--format", choices=("sqlite", "parquet"), required=True)
    parser.add_argument("--out", help="output path (default: inside the run)")
    parser.add_argument("run_dir")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    if not (run_dir / "meta.json").exists():
        print(f"export: {run_dir} is not a run directory", file=sys.stderr)
        raise SystemExit(1)

    if args.format == "sqlite":
        out_path = Path(args.out) if args.out else run_dir / "run.sqlite"
        out_path.unlink(missing_ok=True)
        count = export_sqlite(run_dir, out_path)
        print(f"wrote {out_path} ({count} metric samples)", file=sys.stderr)
    else:
        out_dir = Path(args.out) if args.out else run_dir / "parquet"
        written = export_parquet(run_dir, out_dir)
        print(f"wrote {out_dir}: {', '.join(written)}", file=sys.stderr)


if __name__ == "__main__":
    main()
