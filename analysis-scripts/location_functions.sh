#!/bin/bash
# WiGLE location lookup and summarization.
#
# Shared by summarize_location.sh (single SSID / incremental, called from the
# live capture loop) and standalone_summarize_loc.sh (bulk sweep). The jq
# summarization logic previously existed in three places -- an old grep -A 22
# version in ssid_intel_functions.sh, a rewritten jq version in
# standalone_summarize_loc.sh, and a third copy in summarize_location.sh whose
# database writes were commented out, so it computed a result and discarded it.

# wigle_purge_quota_files
#
# Remove every cached WiGLE body that is a quota-exhaustion message rather than a
# real result, so those SSIDs are retried on a later run instead of caching a
# failure forever. The bulk form of the single-file cleanup wigle_fetch does; the
# retroactive sweep remove_empty_locs() in ssid_intel_functions.sh delegates here
# too, so the logic lives once.
wigle_purge_quota_files () {
	grep -l 'oo many' "${GEO_LOCS_DIR:-locs}"/*.location 2>/dev/null | while read -r f; do
		rm -f "$f"
	done
}

# wigle_fetch <ssid_hex> [on_quota]
#
# Populate locs/<ssid_hex>.location from the WiGLE API if it is not cached yet.
# WiGLE enforces a hard daily quota, and a quota-exhausted body is not a result,
# so the poisoned cache entry is removed to let a later run retry the SSID. What
# happens at that point is set by the second argument:
#
#   stop  (default)  remove this SSID's poisoned entry and return 1, so a caller
#                    looping `wigle_fetch ... || break` stops before burning more
#                    of the daily allowance on failures.
#   exit             the same, but terminate the whole script (exit 1).
#   wait             purge every poisoned entry, sleep $WIGLE_WAIT (default 600s)
#                    and retry the same SSID, blocking until the quota returns --
#                    the daily-grind behavior ssid2loc_every24.sh wants.
#
# Returns 0 once a non-quota response is cached (even an empty or error one),
# non-zero only under `stop` when the quota is gone.
wigle_fetch () {
	local ssid_hex=$1
	local on_quota=${2:-stop}
	local ssid ssid_uri file
	file="${GEO_LOCS_DIR:-locs}/$ssid_hex.location"

	[ -z "$ssid_hex" ] && return 1
	mkdir -p "${GEO_LOCS_DIR:-locs}"

	while true; do
		if [ ! -f "$file" ]; then
			ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null)
			# jq -sRr @uri percent-encodes the SSID for the query string. The old
			# code referenced $ssid_uri without ever assigning it, so every
			# request went out with an empty ssid parameter.
			ssid_uri=$(printf '%s' "$ssid" | jq -sRr @uri)

			curl -s -H 'Accept:application/json' -u "$APIKEY" --basic \
				"https://api.wigle.net/api/v2/network/search?ssid=$ssid_uri" \
				-o "$file"
			# WiGLE rate limits aggressively; stay well under it.
			sleep 2
		fi

		# Anything that is not the quota message is the response the caller
		# asked for -- a result, an empty set, or some other error. Keep it.
		if ! grep -q 'oo many' "$file" 2>/dev/null; then
			return 0
		fi

		# Quota exhausted. The cached body is poison, not a result.
		case "$on_quota" in
			wait)
				echo "WiGLE quota exhausted, waiting ${WIGLE_WAIT:-600}s" >&2
				wigle_purge_quota_files
				sleep "${WIGLE_WAIT:-600}"
				# Loop and retry this SSID; its file was just purged.
				;;
			exit)
				echo "WiGLE quota exhausted, stopping" >&2
				rm -f "$file"
				exit 1
				;;
			*)  # stop
				echo "WiGLE quota exhausted, stopping" >&2
				rm -f "$file"
				return 1
				;;
		esac
	done
}

# test_online
#
# True when the host has working connectivity, for gating the online enrichment
# tier (WiGLE, Nominatim) that idea.txt runs only "when there is internet". Not
# on any current hot path; kept here as the one connectivity check in the tree
# after ssid_intel_online_functions.sh was folded in.
test_online () {
	if ping -c1 -q 4.2.2.2 >/dev/null 2>&1 && nslookup wigle.net >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# summarize_one <ssid_hex>
#
# Reduce a cached WiGLE response to a single human-readable locale string and
# store it in ssid_intel.location.
summarize_one () {
	local ssid_hex=$1
	local ssid file results matches locale
	local -a countries regions cities roads

	# The caller may pass an already-resolved path. The bulk sweep does, from
	# geo_cache_index, which knows all three of the cache's filename
	# conventions -- this fallback only knows the hex one, and so misses the
	# URI-escaped and plain-text files that make up most of a real cache.
	#
	# $GEO_LOCS_DIR rather than a hardcoded `locs/`: geolocate.sh has always
	# honored it, and a hardcoded path meant the two passes could disagree about
	# where the cache is and reach opposite conclusions about the same SSID.
	file=${2:-${GEO_LOCS_DIR:-locs}/$ssid_hex.location}
	ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null)

	if [ ! -f "$file" ]; then
		mysql probeprint <<< "UPDATE ssid_intel SET location='no file' WHERE ssid_hex='$ssid_hex' AND location IS NULL;"
		echo "$ssid_hex (no file)"
		return
	fi

	# A quota-exhausted body has no totalResults at all, so check success first
	# rather than letting jq return the string "null" into an arithmetic test.
	if grep -q 'oo many' "$file" 2>/dev/null; then
		echo "$ssid_hex (quota exhausted, not summarized)"
		return 1
	fi

	results=$(jq -r '.totalResults // empty' "$file" 2>/dev/null)

	if [ -z "$results" ]; then
		mysql probeprint <<< "UPDATE ssid_intel SET location='no results' WHERE ssid_hex='$ssid_hex';"
		echo "$ssid_hex (unparseable)"
		return
	fi
	if [ "$results" -lt 1 ]; then
		mysql probeprint <<< "UPDATE ssid_intel SET location='no results' WHERE ssid_hex='$ssid_hex';"
		echo "$ssid_hex (no results)"
		return
	fi
	if [ "$results" -gt 100 ]; then
		# Too widespread to say anything useful about.
		mysql probeprint <<< "UPDATE ssid_intel SET location='too many results' WHERE ssid_hex='$ssid_hex';"
		echo "$ssid_hex (too many results)"
		return
	fi

	# --arg rather than string interpolation: an SSID containing a double quote
	# would otherwise produce an invalid jq program.
	matches=$(jq --arg s "$ssid" '.results[] | select(.ssid==$s)' "$file" 2>/dev/null)
	if [ -z "$matches" ]; then
		mysql probeprint <<< "UPDATE ssid_intel SET location='no match for ssid' WHERE ssid_hex='$ssid_hex';"
		echo "$ssid_hex (no ssid match)"
		return
	fi

	mapfile -t countries < <(printf '%s' "$matches" | jq -r '.country // empty' | sort -u)
	mapfile -t regions   < <(printf '%s' "$matches" | jq -r '.region  // empty' | sort -u)
	mapfile -t cities    < <(printf '%s' "$matches" | jq -r '.city    // empty' | sort -u)
	mapfile -t roads     < <(printf '%s' "$matches" | jq -r '.road    // empty' | sort -u)

	# Report at the narrowest level the data actually pins down.
	if   [ ${#countries[@]} -eq 1 ] && [ ${#regions[@]} -eq 1 ] && [ ${#cities[@]} -eq 1 ]; then
		locale="${regions[0]} ${cities[0]} ${roads[*]}"
	elif [ ${#countries[@]} -eq 1 ] && [ ${#regions[@]} -eq 1 ]; then
		locale="${regions[0]} (${#cities[@]} cities)"
	elif [ ${#countries[@]} -eq 1 ]; then
		locale="${countries[0]} (${#regions[@]} regions)"
	else
		locale="${#countries[@]} countries"
	fi

	# location is varchar(64); trim rather than let MySQL truncate it silently.
	locale=$(printf '%s' "$locale" | tr -d '"' | cut -c1-64 | sed "s/'/''/g")
	mysql probeprint <<< "UPDATE ssid_intel SET location='${locale}' WHERE ssid_hex='$ssid_hex';"

	echo "$ssid_hex -> $locale"
}

remove_empty_locs () {
	# Retroactively drop quota-exhaustion bodies so those SSIDs retry next run.
	# Single source of the cleanup, shared via location_functions.sh.
	wigle_purge_quota_files
}

# summarize_batch  -- stdin: <ssid_hex>|<file> per line
#
# The bulk equivalent of summarize_one. Same verdicts, same precedence, but one
# jq per file instead of six, and the writes batched instead of one `mysql` per
# SSID.
#
# summarize_one is deliberately left alone: online_wigle_fetch.sh calls it one
# SSID at a time as it fetches, where batching buys nothing, and it is the
# function the tests pin the verdict rules against. This is an additional path,
# not a replacement, and it is checked against summarize_one on a real corpus.
#
# Why one jq: the per-row form ran jq for totalResults, again for the matching
# results, then four more times for country/region/city/road -- six process
# spawns to read one file. A single program computes the whole verdict.
summarize_batch () {
	local sqlf; sqlf=$(mktemp)
	local ssid_hex file ssid verdict
	local n_loc=0 n_none=0 n_many=0 n_nomatch=0 n_quota=0

	echo "start transaction;" > "$sqlf"
	while IFS='|' read -r ssid_hex file; do
		[ -z "$ssid_hex" ] && continue
		# A null byte cannot survive command substitution -- bash drops it and
		# warns -- so the decoded string would be a DIFFERENT SSID than the one
		# probed for. Refuse rather than compare the wrong name.
		case "$ssid_hex" in *00*) continue ;; esac
		ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null)

		# A quota-exhausted body is not a result and must not be recorded as
		# one; it is a file that should be refetched later.
		if grep -q 'oo many' "$file" 2>/dev/null; then
			n_quota=$((n_quota + 1)); continue
		fi

		verdict=$(jq -r --arg s "$ssid" '
			def clean: map(select(. != null and . != "")) | unique;
			if (.totalResults // null) == null then "E|no results"
			elif .totalResults < 1   then "E|no results"
			elif .totalResults > 100 then "E|too many results"
			else
			  ([.results[]? | select(.ssid == $s)]) as $m
			  | if ($m | length) == 0 then "E|no match for ssid"
			    else
			      ([$m[].country] | clean) as $c
			      | ([$m[].region] | clean) as $r
			      | ([$m[].city]   | clean) as $ci
			      | ([$m[].road]   | clean) as $ro
			      | "L|" +
			        (if   ($c|length) == 1 and ($r|length) == 1 and ($ci|length) == 1
			         then ($r[0] + " " + $ci[0] + (if ($ro|length) > 0 then " " + ($ro|join(" ")) else "" end))
			         elif ($c|length) == 1 and ($r|length) == 1
			         then ($r[0] + " (" + (($ci|length)|tostring) + " cities)")
			         elif ($c|length) == 1
			         then ($c[0] + " (" + (($r|length)|tostring) + " regions)")
			         else ((($c|length))|tostring) + " countries"
			         end)
			    end
			end' "$file" 2>/dev/null)

		[ -z "$verdict" ] && verdict="E|no results"

		# location is varchar(64) -- trim rather than let MariaDB truncate with
		# a warning. Double any quote for the SQL literal.
		local val=${verdict#*|}
		val=${val//\"/}
		val=${val:0:64}
		val=${val//\'/\'\'}
		printf "update ssid_intel set location='%s' where ssid_hex='%s';\n" "$val" "$ssid_hex" >> "$sqlf"

		case "$verdict" in
			L\|*) n_loc=$((n_loc + 1)) ;;
			"E|no results")       n_none=$((n_none + 1)) ;;
			"E|too many results") n_many=$((n_many + 1)) ;;
			*)                    n_nomatch=$((n_nomatch + 1)) ;;
		esac
	done
	echo "commit;" >> "$sqlf"
	mysql probeprint < "$sqlf"
	rm -f "$sqlf"

	echo "  resolved to a place   : $n_loc"
	echo "  no results in the body: $n_none"
	echo "  too widespread to use : $n_many"
	echo "  no exact SSID match   : $n_nomatch"
	echo "  quota body, not summarized: $n_quota"
}
