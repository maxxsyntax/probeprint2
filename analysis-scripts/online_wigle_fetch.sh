#!/bin/bash
# Look up and summarize WiGLE locations for SSIDs.
#
# Usage:
#   ./analysis-scripts/online_wigle_fetch.sh <ssid_hex>       one SSID
#   ./analysis-scripts/online_wigle_fetch.sh --new            everything unlocated
#   ./analysis-scripts/online_wigle_fetch.sh --new --wait     wait out the quota and keep going
#   ./analysis-scripts/online_wigle_fetch.sh --new --limit N  only the N most identifying
#   ./analysis-scripts/online_wigle_fetch.sh --new --include-common
#
# RAREST FIRST, THEN MOST RECENTLY HEARD. The quota is the binding constraint --
# WiGLE allows a few hundred lookups a day and there is a mandatory sleep between
# calls, so a real corpus takes years to exhaust and the ORDER is the whole
# decision.
#
# Rarity leads: ssid_intel.rarity descending puts the names that identify a
# person first and 'xfinitywifi' last. But rarity is derived from a global
# sighting corpus, so everything absent from it ties at the maximum, and on a
# real collection that is most of the queue. Recency breaks the tie -- an SSID
# probed for in the last hour belongs to someone who may still be in the
# building, while one last heard months ago is history.
#
# SSIDs flagged is_common are excluded by default: a name shared by thousands of
# access points cannot resolve to one place, so a lookup for it is a wasted call
# whatever it returns. --include-common overrides that.
#
# Candidates include rows already marked 'no file'. That verdict comes from
# summarize_loc and means "the cache holds nothing for this SSID" -- which is
# exactly the set that needs fetching. Selecting them here rather than clearing
# the column first keeps the pass non-destructive: nothing is overwritten until
# a response actually arrives.
#
# Called from build_ssid.sh's capture loop when `online=1` in .env.
#
# This file used to define its functions and then never call them -- both the
# bottom-of-file invocations and the database writes inside summarize_location()
# were commented out, so the live enrichment path computed a result and threw it
# away. Its ssid2loc() also curled ?ssid=$ssid_uri without ever assigning
# ssid_uri, so the request went out empty.
source .env
source ./analysis-scripts/location_functions.sh

if [ $# -eq 0 ]; then
	echo "usage: $0 <ssid_hex> | --new [--wait] [--limit N] [--include-common]" >&2
	exit 1
fi

if [ "$1" = "--new" ]; then
	shift
	# Default to the stop policy; --wait blocks through quota windows instead.
	on_quota=stop
	limit=""
	common_filter="and (is_common is null or is_common = 0)"

	while [ $# -gt 0 ]; do
		case "$1" in
			--wait)           on_quota=wait; shift ;;
			--limit)          limit="limit ${2:?--limit needs a number}"; shift 2 ;;
			--include-common) common_filter=""; shift ;;
			*) echo "unknown option: $1" >&2; exit 1 ;;
		esac
	done

	# Anything the cache cannot answer for: never looked at (null), or looked at
	# and found absent ('no file'). The anomalous hex patterns are skipped --
	# they are not real SSIDs and a lookup for them is a wasted call.
	#
	# `order by rarity desc` is the important line. The quota, not the corpus,
	# is what limits this, so the only question that matters is which SSIDs get
	# spent on. rarity is -ln(sighting frequency), so descending puts the names
	# unique to one household first and the carrier hotspots last. Rows with no
	# rarity score sort to the end rather than being dropped.
	# Two refinements that matter more than they look, because 59,927 of the
	# candidates share the maximum rarity of ~19.7 -- rarity is derived from a
	# global sighting corpus, and anything absent from it scores the same. With
	# that many ties the tie-break IS the priority order.
	#
	#   - names under 4 characters are dropped. "A" is maximally rare by that
	#     metric and completely undiscriminating in a WiGLE query; without this
	#     the first calls of the day go on single letters.
	#   - the name must be word-shaped. Ordering by length alone promoted the
	#     worst candidates in the corpus: 32-character random-symbol strings and
	#     hex blobs are long, maximally rare, and worthless to look up. So a
	#     candidate needs a run of three letters, must not be a bare hex blob,
	#     and must be at least 80% letters/digits/separators rather than a spray
	#     of punctuation.
	#   - MOST RECENTLY SEEN breaks the remaining ties. An SSID probed for in the
	#     last hour belongs to someone who may still be in the building; one last
	#     heard months ago is history. Under a quota that only stretches to a few
	#     hundred lookups a day, spending them on the current room is worth more
	#     than working through the archive.
	#
	# The last-seen join is a group-by over the whole ssid table, which measures
	# at a few hundred ms -- negligible beside the mandatory sleep between API
	# calls, and it runs once per invocation rather than per SSID.
	sql="select i.ssid_hex from ssid_intel i
	      left join (select ssid_hex, max(cast(time as decimal(20,7))) last_seen
	                   from ssid group by ssid_hex) s
	        on s.ssid_hex = i.ssid_hex
	      where (i.location is null or i.location = 'no file')
	        and i.ssid_hex not like '%00%'
	        and i.ssid_hex not like '%fff%'
	        and char_length(unhex(i.ssid_hex)) >= 4
	        and unhex(i.ssid_hex) regexp '[A-Za-z]{3,}'
	        and unhex(i.ssid_hex) not regexp '^[0-9a-fA-F]{12,}\$'
	        and char_length(regexp_replace(unhex(i.ssid_hex), '[^A-Za-z0-9 ._-]', '')) * 10
	            >= char_length(unhex(i.ssid_hex)) * 8
	        ${common_filter//is_common/i.is_common}
	      order by i.rarity is null, i.rarity desc, s.last_seen is null, s.last_seen desc
	      $limit;"

	total=$(mysql -N probeprint <<< "select count(*) from ($sql) t;" 2>/dev/null)
	echo "wigle fetch start $(date +"%H:%M:%S.%3N") -- ${total:-0} candidate(s), rarest and most recently heard first"
	[ "$on_quota" = "wait" ] && echo "  quota policy: wait it out and continue"

	n=0
	while read -r ssid_hex; do
		[ -z "$ssid_hex" ] && continue
		[ "$ssid_hex" = "<MISSING>" ] && continue

		# Under stop, a failed fetch means the quota is gone -- break rather
		# than hammering. Under wait, wigle_fetch blocks until it succeeds and
		# only returns non-zero on a genuine skip, so break is still correct.
		wigle_fetch "$ssid_hex" "$on_quota" || break
		summarize_one "$ssid_hex" || break
		n=$((n + 1))
	done <<< "$(mysql -N probeprint <<< "$sql")"

	echo "wigle fetch stop $(date +"%H:%M:%S.%3N") -- $n looked up"
	exit 0
fi

ssid_hex=$1
wigle_fetch "$ssid_hex" || exit 1
summarize_one "$ssid_hex"
