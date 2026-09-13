#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Kills florestad if the harness stops watching.
#
# A dropped SSH connection has already cost this lab one investigation:
# the node kept running unattended, and afterwards nobody could say
# whether the database was broken or the process had simply been killed
# mid-write.  This closes that hole from the target's side.
#
# The liveness signal is the proc collector's heartbeat file, which it
# rewrites every tick with its own /proc/uptime reading.  The collector
# writes to the SSH channel, so it dies when the harness does -- the
# heartbeat going stale means "nobody is watching", not "the harness is
# busy".  Comparing uptime to uptime keeps this working on a board whose
# wall clock is not to be trusted.
#
# Usage: watchdog.sh <heartbeat-file> <pidfile> <grace-seconds> <own-pidfile>

set -u

HEARTBEAT="$1"
PIDFILE="$2"
GRACE_CS=$(($3 * 100))
OWNPID="$4"

echo $$ >"$OWNPID"
trap 'rm -f "$OWNPID"; exit 0' TERM INT HUP

now_cs() {
	# Concatenated, not computed: the centiseconds are zero-padded and
	# the shell would read "09" as an invalid octal literal.
	read -r _u _ </proc/uptime
	_i="${_u%.*}"
	_f="${_u#*.}"
	if [ "$_f" = "$_u" ]; then
		_f=00
	fi
	case "$_f" in
	?) _f="${_f}0" ;;
	??) ;;
	*) _f="$(printf %.2s "$_f")" ;;
	esac
	echo "${_i}${_f}"
}

while :; do
	sleep 15

	# No pid yet, or the node is already gone: nothing to guard.
	[ -s "$PIDFILE" ] || continue
	read -r pid <"$PIDFILE" || continue
	[ -d "/proc/$pid" ] || continue

	# No heartbeat yet is not staleness; the collector may still be
	# starting.
	[ -s "$HEARTBEAT" ] || continue
	read -r beat <"$HEARTBEAT" || continue

	age=$(($(now_cs) - beat))
	if [ "$age" -gt "$GRACE_CS" ]; then
		echo "watchdog: no heartbeat for $((age / 100))s, stopping florestad (pid $pid)" >&2
		# SIGINT, not SIGKILL: an unwatched shutdown should still be
		# a clean one, so the datadir stays interpretable.
		kill -INT "$pid" 2>/dev/null
		i=0
		while [ -d "/proc/$pid" ] && [ $i -lt 120 ]; do
			sleep 1
			i=$((i + 1))
		done
		[ -d "/proc/$pid" ] && kill -KILL "$pid" 2>/dev/null
		rm -f "$OWNPID"
		exit 0
	fi
done
