#!/bin/bash
# Match SSIDs against an engagement-specific list of organizations, brands or
# projects, in lists/industry.txt.
#
# Shared by ssid_intel_functions.sh and standalone_check_industry.sh so the two
# cannot drift.
#
# --- Three things the previous version got wrong -----------------------------
#
# 1. A blank line was destructive. The loop hex-encoded every line with no
#    validation, so an empty one produced `where ssid_hex like "%"` and
#    relabelled the entire ssid_intel table as INDUSTRY_ORG. A trailing newline
#    in an edited file was enough to trigger it. Blank and comment lines are now
#    skipped, which also means the list can carry comments.
#
# 2. Matching was prefix-only. `Bitcoin` matched "BitcoinCafe" but not
#    "MyBitcoinNet", which is the more common shape for a personal SSID.
#
# 3. Matching was case-sensitive, because it compared hex against hex and the
#    case of the original text is baked into the bytes. `Bitcoin` therefore
#    missed "BITCOIN-guest" and "bitcoin_ap". Decoding in SQL and comparing
#    under the table's utf8mb4_general_ci collation makes LIKE case-insensitive.
#
# Terms shorter than INDUSTRY_MIN_LEN are refused. Substring matching on a
# two- or three-character ticker is indiscriminate: "CC" appears inside
# "Access", "OP" inside "Optimum", "MON" inside "Monitor".
INDUSTRY_MIN_LEN=${INDUSTRY_MIN_LEN:-4}

check_industry () {
	local list=${1:-lists/industry.txt}

	if [ ! -f "$list" ]; then
		echo "check_industry: $list not found, skipping" >&2
		return 0
	fi

	echo "industry start $(date +"%H:%M:%S.%3N")"
	local term esc matched=0 skipped=0

	while IFS= read -r term || [ -n "$term" ]; do
		# Strip CR from a file edited on Windows, and surrounding whitespace.
		term=${term%$'\r'}
		term="${term#"${term%%[![:space:]]*}"}"
		term="${term%"${term##*[![:space:]]}"}"

		[ -z "$term" ] && continue                 # blank: would match everything
		case "$term" in \#*) continue ;; esac      # comment

		if [ "${#term}" -lt "$INDUSTRY_MIN_LEN" ]; then
			echo "  skipping '$term': shorter than $INDUSTRY_MIN_LEN chars, too broad to match safely" >&2
			skipped=$((skipped + 1))
			continue
		fi

		# Single-quoted SQL literal, so double any embedded quote.
		esc=${term//\'/\'\'}

		# convert(... using utf8mb4) decodes the stored hex back to text so the
		# comparison happens on the network name. Invalid byte sequences yield
		# NULL and simply do not match, which is correct for anomalous SSIDs.
		mysql probeprint <<SQL
update ssid_intel
   set category = "INDUSTRY_ORG"
 where convert(unhex(ssid_hex) using utf8mb4) like '%${esc}%';
SQL
		matched=$((matched + 1))
	done < "$list"

	echo "  terms applied: $matched   terms refused as too short: $skipped"
	echo "industry stop $(date +"%H:%M:%S.%3N")"
}
