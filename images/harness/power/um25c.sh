#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Power driver: RDTech UM25C / UM24C / UM34C inline USB meter.
#
# Driver contract (identical for every meter, see images/harness/README.md):
#   * reads its configuration from BENCH_POWER_DEVICE and BENCH_POWER_RATE
#   * writes "t_ms,volts,amps,watts" lines to stdout, one per sample
#   * exits cleanly on SIGTERM, flushing whatever it has
#   * writes diagnostics to stderr only
#
# A new meter is a new file next to this one and a new value for
# --power-meter.  Nothing in the orchestrator knows what a UM25C is.
#
# The meter speaks a request/response protocol over a serial port: send
# one 0xF0 byte, get 130 bytes back.  Over Bluetooth that is an rfcomm
# node, over USB a CDC-ACM device; both look the same from here.
#
#   rfcomm bind 0 <mac> 1     # then BENCH_POWER_DEVICE=/dev/rfcomm0
#
# NOT YET EXERCISED ON HARDWARE: the lab has no inline meter yet, so the
# frame layout below comes from the published protocol, not from a
# capture.  The model word at offset 0 is checked precisely so that a
# wrong device or a wrong scaling factor fails loudly instead of
# silently reporting plausible watts.

set -euo pipefail

DEVICE="${BENCH_POWER_DEVICE:-/dev/rfcomm0}"
RATE="${BENCH_POWER_RATE:-10}"
BAUD="${BENCH_POWER_BAUD:-9600}"

[ -e "$DEVICE" ] || {
	echo "um25c: no such device: $DEVICE" >&2
	exit 1
}

stty -F "$DEVICE" "$BAUD" raw -echo -echoe -echok -crtscts min 0 time 10 2>/dev/null || {
	echo "um25c: cannot configure $DEVICE" >&2
	exit 1
}

exec python3 - "$DEVICE" "$RATE" <<'PYEOF'
import os
import signal
import struct
import sys
import time

device, rate = sys.argv[1], float(sys.argv[2])
period = 1.0 / rate if rate > 0 else 0.1

# model word -> (volt divisor, amp divisor).  The UM24C counts in
# hundredths of a volt and milliamps; the UM25C and UM34C are ten times
# finer.  Getting this wrong scales every joule in the report by 10, so
# an unknown model is a hard error.
MODELS = {
    0x09C9: ("UM24C", 100.0, 1000.0),
    0x0963: ("UM25C", 1000.0, 10000.0),
    0x0D4C: ("UM34C", 100.0, 1000.0),
}

running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

fd = os.open(device, os.O_RDWR | os.O_NOCTTY)
model = None

try:
    while running:
        deadline = time.time() + period
        try:
            os.write(fd, b"\xf0")
        except OSError as exc:
            print(f"um25c: write failed: {exc}", file=sys.stderr)
            break

        buf = b""
        # The reply is 130 bytes; short reads are normal on a serial
        # line, so accumulate until the frame is whole or the sample
        # slot expires.
        while len(buf) < 130 and time.time() < deadline:
            try:
                chunk = os.read(fd, 130 - len(buf))
            except BlockingIOError:
                chunk = b""
            if not chunk:
                time.sleep(0.005)
                continue
            buf += chunk

        if len(buf) < 130:
            print("um25c: short frame, skipping sample", file=sys.stderr)
            continue

        if model is None:
            word = struct.unpack(">H", buf[0:2])[0]
            if word not in MODELS:
                print(
                    f"um25c: unknown model word 0x{word:04x} -- refusing to "
                    "guess the scaling factors",
                    file=sys.stderr,
                )
                sys.exit(1)
            model = MODELS[word]
            print(f"um25c: detected {model[0]}", file=sys.stderr)

        _name, vdiv, adiv = model
        volts = struct.unpack(">H", buf[2:4])[0] / vdiv
        amps = struct.unpack(">H", buf[4:6])[0] / adiv
        watts = struct.unpack(">I", buf[6:10])[0] / 1000.0

        t_ms = int(time.time() * 1000)
        print(f"{t_ms},{volts:.4f},{amps:.5f},{watts:.4f}", flush=True)

        remaining = deadline - time.time()
        if remaining > 0:
            time.sleep(remaining)
finally:
    os.close(fd)
PYEOF
