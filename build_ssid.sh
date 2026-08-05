#!/bin/bash
#set -x
source .env
source ./ingest_functions.sh

mkfifo pipe 2>/dev/null

listen () {
iwconfig "$INF" channel 6
 while true; do

# -V was dropped: it makes tshark build the full protocol detail tree, which is
# wasted work when only -T fields output is consumed.
tshark -Qi "$INF" -a duration:3 -f "wlan subtype probe-req" "${PROBE_TSHARK_ARGS[@]}" 2>/dev/null > pipe
done
}

tshark2db () {
while true; do
	# The parse loop lives in ingest_functions.sh, shared with
	# client/build_ssid.sh and pcap2db.sh.
	ingest_stream < pipe

	# Live WiGLE enrichment for whatever arrived in this window. Gated on
	# `online` from .env because it makes rate-limited network calls.
	# Quote the test: with `online` unset, `[ $online -eq 1 ]` was a hard error.
	if [ "$online" = "1" ]; then
		./summarize_location.sh --new
	fi

	sleep .1
done
}

listen &
tshark2db &



trap 'kill $(jobs -p)' EXIT
wait
