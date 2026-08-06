#!/bin/bash
# WiGLE location lookup and summarization.
#
# Shared by summarize_location.sh (single SSID / incremental, called from the
# live capture loop) and standalone_summarize_loc.sh (bulk sweep). The jq
# summarization logic previously existed in three places -- an old grep -A 22
# version in ssid_intel_functions.sh, a rewritten jq version in
# standalone_summarize_loc.sh, and a third copy in summarize_location.sh whose
# database writes were commented out, so it computed a result and discarded it.

# wigle_fetch <ssid_hex>
#
# Populate locs/<ssid_hex>.location from the WiGLE API if it is not cached yet.
# Returns 1 if the API says the quota is exhausted, so callers can stop early
# rather than burning the remaining daily allowance on failures.
wigle_fetch () {
	local ssid_hex=$1
	local ssid ssid_uri file
	file="locs/$ssid_hex.location"

	[ -z "$ssid_hex" ] && return 1
	mkdir -p locs

	if [ ! -f "$file" ]; then
		ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null)
		# jq -sRr @uri percent-encodes the SSID for the query string. The old
		# code referenced $ssid_uri without ever assigning it, so every request
		# went out with an empty ssid parameter.
		ssid_uri=$(printf '%s' "$ssid" | jq -sRr @uri)

		curl -s -H 'Accept:application/json' -u "$APIKEY" --basic \
			"https://api.wigle.net/api/v2/network/search?ssid=$ssid_uri" \
			-o "$file"
		# WiGLE rate limits aggressively; stay well under it.
		sleep 2
	fi

	# A quota-exhausted response is not a result. Remove the poisoned cache
	# entry so a later run can retry this SSID.
	if grep -q 'oo many' "$file" 2>/dev/null; then
		echo "WiGLE quota exhausted, stopping" >&2
		rm -f "$file"
		return 1
	fi

	return 0
}

# summarize_one <ssid_hex>
#
# Reduce a cached WiGLE response to a single human-readable locale string and
# store it in ssid_intel.location.
summarize_one () {
	local ssid_hex=$1
	local ssid file results matches locale
	local -a countries regions cities roads

	file="locs/$ssid_hex.location"
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
