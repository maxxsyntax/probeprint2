#!/bin/bash
#set -x
source .env
source ./capture-scripts/ingest_functions.sh

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
		./analysis-scripts/online_wigle_fetch.sh --new
	fi

	# Geolocation is off during capture by default and belongs in a post-capture
	# pass -- every provider is rate limited, and blocking the ingest loop on a
	# network round trip costs frames. Set geo_online=1 in .env only if you need
	# coordinates live on the display; it reads the locs/ cache and makes no
	# calls of its own.
	if [ "${geo_online:-0}" = "1" ]; then
		./analysis-scripts/geolocate.sh >/dev/null 2>&1
	fi

	sleep .1
done
}

listen &
tshark2db &



trap 'kill $(jobs -p)' EXIT
wait
