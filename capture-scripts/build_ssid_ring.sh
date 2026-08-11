#!/bin/bash
# Live capture via a dumpcap ring buffer, ingesting closed files.
#
# An alternative to build_ssid.sh's tshark-straight-into-mysql path. The pcap on
# disk is the system of record; the database is a derived index. Two independent
# stages, so neither can stall the other:
#
#   1. dumpcap writes probe requests to a rotating set of pcap files in a spool
#      directory. dumpcap is engineered for lossless capture -- it does nothing
#      but move frames from the kernel to disk -- so a slow or locked database
#      never costs a frame on the air. This is the stage build_ssid.sh cannot
#      offer: there, a blocked INSERT blocks the reader draining the capture.
#   2. A watcher ingests each pcap once dumpcap has rotated past it (so only
#      closed files are ever read), through the same ingest_stream as every
#      other path, then archives it to done/.
#
# Why this shape, over piping tshark into the DB (see build_ssid.sh):
#   - Re-parseable. The pipeline keeps gaining fields (wps.uuid_e, the HT
#     subfields, frame.len). A frame parsed straight into the DB has thrown its
#     bytes away, so a field added later is gone for every historical row. An
#     archived pcap is one re-import away: point ./capture.sh --pcap-dir at
#     done/ after adding the field and the old frames backfill it.
#   - Lossless under DB contention. See stage 1.
#   - Recoverable. A parser bug (cf. the historical space-separator corruption
#     in CLAUDE.md) is fixable by re-importing; without the pcap there is none.
#
# The cost is latency: a frame is not queryable until its file rotates and is
# ingested, so RING_SECS is the freshness floor. Enrichment is post-capture
# anyway, and a few seconds is fine for the display's near/medium/far banding.
#
# Run from the repo root, like everything else: ./capture.sh --ring
source .env
source ./capture-scripts/ingest_functions.sh

# --- knobs (all overridable from .env) -------------------------------------
# The spool holds files dumpcap is still cycling through; ingested files move to
# done/, kept as the system of record. done/ holds raw frames -- real PII -- so
# it lives inside the workspace and is gitignored, and cleaning it is an
# engagement decision, not this script's job.
RING_DIR=${RING_DIR:-spool}
RING_SECS=${RING_SECS:-5}      # seconds per file: the freshness floor
RING_FILES=${RING_FILES:-720}  # spool ring cap; a backstop if the watcher stalls
RING_KEEP=${RING_KEEP:-1}      # 1 archive ingested pcaps to done/, 0 delete them
RING_SLACK=${RING_SLACK:-2}    # extra seconds before a file is deemed closed

mkdir -p "$RING_DIR"
[ "$RING_KEEP" = "1" ] && mkdir -p "$RING_DIR/done"

# Same capture filter string as build_ssid.sh, so this path stores exactly the
# set of frames that one does. dumpcap and tshark share wireshark's capture
# filter engine, so a string proven with `tshark -f` works with `dumpcap -f`.
RING_BPF=${RING_BPF:-"wlan subtype probe-req"}

# Display filter for the read side, matching pcap2db.sh -- "is a probe request"
# expressed so wildcard/broadcast probes (a zero-length IE) are kept, not
# dropped. See the long note in pcap2db.sh.
RING_READ_FILTER="wlan.fc.type_subtype == 4"

# --- stage 1: dumpcap per interface ----------------------------------------
# One dumpcap per INF token, each to its own base name so their ring files never
# collide. dumpcap expands `-w base.pcap -b ...` into base_NNNNN_TIMESTAMP.pcap.
# Channel handling mirrors build_ssid.sh: `iface:N` parks the radio on N first.
start_dumpcap () {
	local iface=$1 chan=$2
	[ -n "$chan" ] && iwconfig "$iface" channel "$chan" 2>/dev/null
	# -q: dumpcap's per-packet count chatter is noise here. -P: write classic
	# pcap, which tshark -r on the ingest side reads without question.
	dumpcap -q -P -i "$iface" -f "$RING_BPF" \
		-b duration:"$RING_SECS" -b files:"$RING_FILES" \
		-w "$RING_DIR/probe_${iface}.pcap" 2>/dev/null &
}

# --- stage 2: ingest closed files ------------------------------------------
# A file is safe to read once dumpcap has stopped writing it. Rather than parse
# dumpcap's rotation numbering, treat a file as closed once its mtime has been
# still for longer than one rotation interval: dumpcap keeps the open file's
# mtime current, so anything older than RING_SECS+RING_SLACK has definitely
# rotated out. No filename parsing, and correct across any number of interfaces
# writing at once.
ingest_closed () {
	local age=$((RING_SECS + RING_SLACK)) cutoff f
	# An absolute ISO cutoff, `age` seconds in the past. Passed to -newermt as a
	# concrete timestamp rather than the relative "N seconds ago" form, because
	# that relative form is a GNU-find extension bfs (and others) reject, while
	# an ISO 8601 timestamp is understood by both. GNU `date -d` builds it, which
	# this tree already depends on (cf. `date +%N` throughout).
	cutoff=$(date -d "$age seconds ago" '+%Y-%m-%dT%H:%M:%S')
	# -not -newermt "$cutoff": last modified at or before the cutoff, i.e. dumpcap
	# has moved on from it.
	while IFS= read -r f; do
		[ -f "$f" ] || continue

		# Read the closed pcap through the shared parse loop. ENGAGEMENT is left
		# in force (unlike pcap2db.sh, which clears it to tag rows by filename):
		# this is live capture, so rows carry the engagement tag exactly as
		# build_ssid.sh's live path writes them.
		tshark -Qr "$f" -Y "$RING_READ_FILTER" "${PROBE_TSHARK_ARGS[@]}" 2>/dev/null \
			| ingest_stream

		if [ "$RING_KEEP" = "1" ]; then
			mv -f "$f" "$RING_DIR/done/"
		else
			rm -f "$f"
		fi
	done < <(find "$RING_DIR" -maxdepth 1 -name 'probe_*.pcap' \
	              -not -newermt "$cutoff" | sort)
}

# --- wire it together ------------------------------------------------------
started=0
for token in $INF; do
	case "$token" in
		*:*) start_dumpcap "${token%%:*}" "${token##*:}" ;;
		*)   start_dumpcap "$token" "" ;;
	esac
	started=$((started + 1))
done
[ "$started" -eq 0 ] && { echo "INF is not set -- no interface to capture from" >&2; exit 1; }
echo "ring capture on $started interface(s): $INF"
echo "  spool=$RING_DIR  file=${RING_SECS}s  archive=$([ "$RING_KEEP" = 1 ] && echo "$RING_DIR/done" || echo off)"

# Kill the dumpcap children on the way out, and drain whatever is already closed
# so a clean Ctrl-C does not strand the last few files unread.
trap 'kill $(jobs -p) 2>/dev/null; ingest_closed' EXIT

while true; do
	ingest_closed

	# Live WiGLE enrichment for whatever just landed, gated on `online` exactly
	# as build_ssid.sh gates it. Quoted so an unset `online` is not a hard error.
	if [ "$online" = "1" ]; then
		./analysis-scripts/online_wigle_fetch.sh --new
	fi
	if [ "${geo_online:-0}" = "1" ]; then
		./analysis-scripts/geolocate.sh >/dev/null 2>&1
	fi

	sleep "$RING_SECS"
done
