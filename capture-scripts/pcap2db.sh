#!/bin/bash
# Backfill the ssid table from saved capture files.
#
# Usage: ./capture-scripts/pcap2db.sh <capture.pcap> [more.pcap ...]
#
# Rows imported from a file are tagged with that filename in ssid.tag, so a
# backfilled batch can be told apart from live capture afterwards.
source ./capture-scripts/ingest_functions.sh
[ -f .env ] && source .env

# Database connection, matching client/build_ssid.sh so a backfill can target a
# remote collection host as well as the local one. Both default to empty, in
# which case mysql connects as the invoking unix user over the socket -- which
# is what the rest of the tree assumes, and what ~/.my.cnf can supply.
DB_ARGS=()
[ -n "${DB_USER:-}" ] && DB_ARGS+=(-u "$DB_USER")
[ -n "${DB_HOST:-}" ] && DB_ARGS+=(-h "$DB_HOST")

if [ $# -eq 0 ]; then
	echo "usage: $0 <capture.pcap> [...]" >&2
	exit 1
fi

# Check for tshark up front. Every tshark call below sends stderr to /dev/null
# and counts lines out of the pipe, so a missing binary produces zero matches
# and is indistinguishable from a capture with no radiotap headers -- the loop
# would report "has No radiotap headers" for every file handed to it, including
# files that do have them.
if ! command -v tshark >/dev/null 2>&1; then
	echo "tshark is not installed, so no capture can be read." >&2
	echo "  Debian/Ubuntu: sudo apt-get install -y tshark" >&2
	echo "  Or run this inside the test container, which already has it." >&2
	exit 1
fi

# Probe requests only, matching the live capture filter in build_ssid.sh
# ("wlan subtype probe-req") so both ingest paths store the same set of rows.
#
# This previously read `... and wlan.tag.length != 0`. In Wireshark display
# filter semantics `!=` means "no occurrence equals", not "some occurrence
# differs", so that clause excluded any probe containing a zero-length IE --
# which is every wildcard/broadcast probe. Live capture stored those as
# <MISSING> while pcap import silently dropped them.
PROBE_FILTER="wlan.fc.type_subtype == 4"

for capture in "$@"; do
	if [ ! -f "$capture" ]; then
		echo "$capture: no such file" >&2
		continue
	fi

	# Without radiotap there is no RSSI or channel, which the burst-grouping
	# passes correlate on. The old check combined `-a packets:1` with a display
	# filter and then tested `-eq 1`, so it reported "No radiotap headers" for
	# any capture whose first frame was not itself a probe request.
	has_radiotap=$(tshark -Qr "$capture" -Y "$PROBE_FILTER" \
		-T fields -e wlan_radio.frequency 2>/dev/null | grep -cE '^[0-9]+$')

	if [ "$has_radiotap" -eq 0 ]; then
		echo "$capture has No radiotap headers"
		continue
	fi

	# Window covering every probe in this file, used to tag the imported rows.
	begintime=$(tshark -Qr "$capture" -Y "$PROBE_FILTER" -T fields \
		-e frame.time_epoch 2>/dev/null | head -n1)
	endtime=$(tshark -Qr "$capture" -Y "$PROBE_FILTER" -T fields \
		-e frame.time_epoch 2>/dev/null | tail -n1)

	if [ -z "$begintime" ] || [ -z "$endtime" ]; then
		echo "$capture contains no probe requests"
		continue
	fi

	# Widen the window slightly so the first and last rows fall inside it.
	# The old version truncated begintime with `cut -d. -f1`, throwing away the
	# fractional second.
	begintime=$(echo "scale=7; $begintime - .0001" | bc)
	endtime=$(echo "scale=7; $endtime + .0001" | bc)

	echo "== importing $capture ($begintime .. $endtime) =="

	# Straight pipe, rather than the old detour through a hardcoded
	# /usr/src/probeprint/pipe fifo that existed only on the author's machine.
	tshark -Qr "$capture" -Y "$PROBE_FILTER" "${PROBE_TSHARK_ARGS[@]}" 2>/dev/null \
		| ingest_stream "${DB_ARGS[@]}"

	# Tag the rows this file contributed. The previous version issued this as a
	# `sqlite3 new.db` update -- a leftover from before the MariaDB migration --
	# so the tag was never actually written to the live database.
	mysql "${DB_ARGS[@]}" probeprint <<SQL
update ssid set tag = "$capture"
where time > "$begintime" and time < "$endtime" and tag is null;
SQL
done
