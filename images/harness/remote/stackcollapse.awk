# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Fold `perf script` output into one line per sample, on the target.
#
# Sending folded text instead of perf.data means the host never has to
# decode another architecture's binary format, and the transfer is a
# few hundred KB instead of tens of MB over a USB gadget link.
#
# Unlike the usual stackcollapse-perf.pl this keeps each sample's
# timestamp on its own line rather than aggregating immediately:
# aggregation throws away exactly the information needed to cut the
# profile by window, and the host can aggregate at leisure.
#
# Output: "<monotonic seconds> comm;frame;frame;leaf"

/^[ \t]*$/ {
	if (nframes > 0) {
		stack = comm
		# perf prints leaf first; a flamegraph reads root first.
		for (i = nframes; i >= 1; i--) {
			stack = stack ";" frames[i]
		}
		printf "%s %s\n", ts, stack
	}
	nframes = 0
	next
}

# Header: "comm pid/tid [cpu] timestamp: period event:"
/^[^ \t]/ {
	comm = $1
	gsub(/[;: ]/, "_", comm)
	ts = "0"
	for (i = 2; i <= NF; i++) {
		if ($i ~ /^[0-9]+\.[0-9]+:$/) {
			ts = substr($i, 1, length($i) - 1)
			break
		}
	}
	nframes = 0
	next
}

# Frame: "	<addr> <symbol>+<offset> (<dso>)"
{
	line = $0
	sub(/^[ \t]+/, "", line)
	sub(/^[0-9a-fA-F]+ /, "", line)
	sub(/ \([^)]*\)$/, "", line)
	sub(/\+0x[0-9a-fA-F]+$/, "", line)
	if (line == "") {
		line = "[unknown]"
	}
	gsub(/;/, ":", line)
	nframes++
	frames[nframes] = line
}
