#!/bin/bash
#set -x
source .env
source ./capture-scripts/ingest_functions.sh

# INF is a whitespace-separated list of capture interfaces, so one rig can watch
# several channels at once -- which is the whole point of a second radio, since
# a single interface only ever hears the channel it is parked on. Each token is
# an interface, optionally with a channel: "wlan1mon:1 wlan2mon:6 wlan3mon:11".
#
#   iface           capture on whatever channel the interface is already set to
#   iface:N         set the interface to channel N first
#
# A single bare interface (INF="wlan1mon") is still valid and behaves as before,
# except the channel is no longer forced -- set it yourself, or use iface:6.
# Every interface feeds one shared fifo; a probe-request field row is far under
# PIPE_BUF, so concurrent writers interleave by whole lines, never mid-line.

mkfifo pipe 2>/dev/null

# listen <iface> [channel] -- restart tshark on this interface forever, writing
# probe requests into the shared pipe.
listen () {
	local iface=$1 chan=$2
	[ -n "$chan" ] && iwconfig "$iface" channel "$chan" 2>/dev/null
	while true; do
		# -V was dropped: it makes tshark build the full protocol detail tree,
		# which is wasted work when only -T fields output is consumed.
		tshark -Qi "$iface" -a duration:3 -f "wlan subtype probe-req" \
			"${PROBE_TSHARK_ARGS[@]}" 2>/dev/null > pipe
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

# One listener per interface, all writing to the shared pipe; one reader.
# The channel is passed only when the token actually contains a colon --
# ${token#*:} returns the whole token unchanged when there is none, so testing
# for the colon here is what keeps a bare "wlan1mon" from being read as a
# channel named "wlan1mon".
started=0
for token in $INF; do
	case "$token" in
		*:*) listen "${token%%:*}" "${token##*:}" & ;;
		*)   listen "$token" "" & ;;
	esac
	started=$((started + 1))
done
[ "$started" -eq 0 ] && { echo "INF is not set -- no interface to capture from" >&2; exit 1; }
echo "capturing on $started interface(s): $INF"

tshark2db &

trap 'kill $(jobs -p)' EXIT
wait
