#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Replay a finished run's metrics into a live Prometheus.

Exploring a run visually is worth a lot; doing it *during* the run costs
the board CPU it does not have.  So the exposition is stored raw while
the board is busy, and replayed afterwards at whatever speed suits.

    bench-node serve-prom runs/2026…/        # then point Prometheus at :9099

Wall-clock time since this server started maps onto run time, so a
Prometheus scraping it at 5s records the run as if it were happening
now.  --speed compresses that; --at freezes a single instant.
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Replay:
    def __init__(self, run_dir, speed, frozen_at):
        self.scrapes = []
        path = Path(run_dir) / "metrics.jsonl"
        for line in path.read_text().splitlines():
            try:
                scrape = json.loads(line)
            except json.JSONDecodeError:
                continue
            if scrape.get("ok") and scrape.get("body"):
                self.scrapes.append((scrape["t_ms"], scrape["body"]))
        self.scrapes.sort()
        if not self.scrapes:
            raise SystemExit("serve-prom: metrics.jsonl holds no successful scrapes")
        self.t0 = self.scrapes[0][0]
        self.t_end = self.scrapes[-1][0]
        self.speed = speed
        self.frozen_at = frozen_at
        self.started = time.time()

    def body_now(self):
        if self.frozen_at is not None:
            want = self.t0 + self.frozen_at * 1000
        else:
            elapsed_ms = (time.time() - self.started) * 1000 * self.speed
            want = self.t0 + elapsed_ms
            if want > self.t_end:
                # Past the end of the run, hold the last state rather
                # than looping: a looping counter reads as a restart.
                want = self.t_end
        best = self.scrapes[0]
        for t_ms, body in self.scrapes:
            if t_ms <= want:
                best = (t_ms, body)
            else:
                break
        return best


def make_handler(replay):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path.rstrip("/") not in ("", "/metrics"):
                self.send_error(404)
                return
            t_ms, body = replay.body_now()
            payload = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("X-Bench-Node-Scrape-Ms", str(t_ms))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser(prog="bench-node serve-prom")
    parser.add_argument("--port", type=int, default=9099)
    parser.add_argument("--speed", type=float, default=1.0, help="replay speed multiplier")
    parser.add_argument("--at", type=float, help="freeze at N seconds into the run")
    parser.add_argument("run_dir")
    args = parser.parse_args()

    replay = Replay(args.run_dir, args.speed, args.at)
    duration = (replay.t_end - replay.t0) / 1000.0
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(replay))
    print(
        f"serving {len(replay.scrapes)} scrapes ({duration:.0f}s of run) at "
        f"http://127.0.0.1:{args.port}/metrics at {args.speed}x",
    )
    print("point Prometheus at that address; Ctrl-C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
