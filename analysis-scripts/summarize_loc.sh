#!/bin/bash
# Bulk sweep: summarize cached WiGLE responses for every SSID lacking a location.
#
# Offline by design -- it reads whatever is already cached in $GEO_LOCS_DIR and
# never calls the API. Use online_wigle_fetch.sh when you want fetching too.
#
# The jq summarization itself lives in location_functions.sh, shared with
# online_wigle_fetch.sh so the two paths cannot drift apart.
#
# The sweep resolves filenames through geo_cache_index rather than probing the
# filesystem per SSID. That is both faster -- one directory read instead of a
# stat per row -- and more correct: the cache uses three filename conventions
# (hex, URI-escaped, plain text) and this pass only ever knew the first, so on a
# real cache it reported "no file" for most of what it actually had.
#
# The overwhelming majority of rows have no cached response at all, and those
# are now written in one batched statement instead of a `mysql` invocation each.
# jq is still forked per SSID that DOES have a file, which is unavoidable and
# bounded by the cache size rather than the corpus size.
source .env
source ./analysis-scripts/location_functions.sh
source ./analysis-scripts/geolocate_functions.sh

echo "summarize_location start $(date +"%H:%M:%S.%3N")"

if ! geo_cache_index; then
	echo "  no cached WiGLE responses under '${GEO_LOCS_DIR:-locs}' -- nothing to summarize." >&2
	echo "  Point GEO_LOCS_DIR at the cache, or fetch with ./analysis-scripts/online_wigle_fetch.sh --new." >&2
	echo "summarize_location end $(date +"%H:%M:%S.%3N")"
	exit 0
fi
echo "  indexed ${#GEO_CACHE_FILE[@]} cached responses in ${GEO_LOCS_DIR:-locs}"

nofile=$(mktemp)
havefile=$(mktemp)
n_have=0 n_none=0

# Split the work first: the rows with a cached response go to summarize_batch as
# one stream, the rest become a single batched "no file" statement. Splitting is
# what lets the common case -- no cached response, the overwhelming majority --
# cost nothing per row.
while read -r ssid_hex; do
	[ -z "$ssid_hex" ] && continue
	file=${GEO_CACHE_FILE[$ssid_hex]:-}
	if [ -n "$file" ] && [ -f "$file" ]; then
		printf '%s|%s\n' "$ssid_hex" "$file" >> "$havefile"
		n_have=$((n_have + 1))
	else
		printf '%s\n' "$ssid_hex" >> "$nofile"
		n_none=$((n_none + 1))
	fi
done <<< "$(mysql -N probeprint <<< "SELECT ssid_hex FROM ssid_intel WHERE location IS NULL;")"

[ -s "$havefile" ] && summarize_batch < "$havefile"
rm -f "$havefile"

# One statement per 1000, rather than one per SSID.
if [ -s "$nofile" ]; then
	{
		echo "start transaction;"
		awk 'BEGIN { n = 0 }
		{
			if (n % 1000 == 0) {
				if (n > 0) print ");"
				printf "update ssid_intel set location=\"no file\" where location is null and ssid_hex in ("
				first = 1
			}
			printf "%s\"%s\"", (first ? "" : ","), $0
			first = 0
			n++
		}
		END { if (n > 0) print ");" }' "$nofile"
		echo "commit;"
	} | mysql probeprint
fi
rm -f "$nofile"

echo "  summarized from a cached response : $n_have"
echo "  no cached response                : $n_none"
echo "summarize_location end $(date +"%H:%M:%S.%3N")"
