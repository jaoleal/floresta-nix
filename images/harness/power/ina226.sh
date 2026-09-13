#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Power driver: INA226 high-side shunt monitor on a support
# microcontroller, streaming ASCII over a serial link.
#
# Driver contract: see the header of um25c.sh.  This one exists mostly
# to prove the contract is real -- it shares no code with the UM25C
# driver and speaks a completely different protocol, yet the harness
# treats them identically.
#
# The microcontroller is expected to free-run, printing one sample per
# line as either
#
#     <volts> <amps>
#     <volts>,<amps>
#     <volts>,<amps>,<watts>
#
# Watts are computed as volts*amps when the firmware does not send them.
# Lines that do not parse are counted and reported to stderr rather than
# silently dropped, because a meter that quietly emits garbage is worse
# than no meter at all.
#
# NOT YET EXERCISED ON HARDWARE.

set -euo pipefail

DEVICE="${BENCH_POWER_DEVICE:-/dev/ttyUSB0}"
BAUD="${BENCH_POWER_BAUD:-115200}"

[ -e "$DEVICE" ] || {
	echo "ina226: no such device: $DEVICE" >&2
	exit 1
}

stty -F "$DEVICE" "$BAUD" raw -echo -echoe -echok -crtscts 2>/dev/null || {
	echo "ina226: cannot configure $DEVICE" >&2
	exit 1
}

# Timestamps are taken here, on the host, at the moment the line
# arrives.  The link adds a millisecond or two of latency; that is
# recorded honestly as meter-vs-host offset in meta.json rather than
# pretended away.
exec awk '
	{
		gsub(/,/, " ")
		if (NF < 2) { bad++; next }
		v = $1 + 0; a = $2 + 0
		w = (NF >= 3) ? $3 + 0 : v * a
		if (v <= 0 && a <= 0) { bad++; next }
		"date +%s%3N" | getline t
		close("date +%s%3N")
		printf "%s,%.4f,%.5f,%.4f\n", t, v, a, w
		fflush()
	}
	END {
		if (bad > 0) printf "ina226: %d unparseable lines\n", bad > "/dev/stderr"
	}
' <"$DEVICE"
