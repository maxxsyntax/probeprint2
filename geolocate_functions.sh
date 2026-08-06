#!/bin/bash
# Turn network identifiers into coordinates and street addresses.
#
# --- The providers are NOT interchangeable -----------------------------------
#
# This is the thing to understand before using any of it. They take different
# inputs and answer different questions:
#
#   WiGLE      SSID or BSSID  ->  where that access point is
#              The only one that accepts an SSID, which is all an undirected
#              probe request gives you. Already used by location_functions.sh;
#              its cached responses in locs/ carry trilat/trilong.
#
#   Google     a set of BSSIDs -> where the OBSERVER is
#              Not where any one AP is. Google's Geolocation API is built for
#              "given the APs I can hear, where am I", so it locates the
#              capture point, not the network. Submitting a single BSSID
#              usually returns notFound. Useful for fixing where a directed
#              probe burst was seen; useless for locating one SSID.
#
#   Apple      one BSSID -> that AP's position, plus its neighbours
#              This is the one that does per-AP lookup, but there is no public
#              API. The endpoint is undocumented and protobuf-framed, and Rye &
#              Levin (2024) showed it returns hundreds of nearby APs per query,
#              which is why it is a documented mass-surveillance concern.
#              Disabled by default. See geo_apple_bssid.
#
#   Nominatim  lat/lon -> street address
#              Reverse geocoding only. Free, and bound by OSM's policy of one
#              request per second with an identifying User-Agent.
#
# So the working chain for an SSID is WiGLE for the fix and Nominatim for the
# address. Google and Apple only become available at all when directed probe
# requests give up a BSSID, which is why ingest now captures wlan.da.
#
# --- Configuration, from .env ------------------------------------------------
#   GOOGLE_GEOLOCATION_KEY   enables the Google provider
#   GEO_ENABLE_APPLE=1       opt in to the undocumented Apple endpoint
#   GEO_USER_AGENT           sent to Nominatim; its policy requires a real one
#   GEO_NOMINATIM_SLEEP      seconds between reverse geocodes (default 1)

GEO_USER_AGENT=${GEO_USER_AGENT:-probeprint2-geolocate}
GEO_NOMINATIM_SLEEP=${GEO_NOMINATIM_SLEEP:-1}
GEO_ENABLE_APPLE=${GEO_ENABLE_APPLE:-0}

# ---------------------------------------------------------------------------
# WiGLE, from the cache. No network access.
# ---------------------------------------------------------------------------
#
# The cache has two naming conventions, because an older code path wrote
# locs/"$ssid_uri".location -- the percent-encoded SSID text -- before it
# settled on locs/"$ssid_hex".location. A real collection contains both, and
# looking only for the hex name misses most of it.
#
# The two are not always distinguishable from the filename alone: "abcdef" is
# both valid hex and a plausible network name. So each candidate reading is
# checked against the file's own contents, since WiGLE echoes the SSID of every
# result it returns.

GEO_LOCS_DIR=${GEO_LOCS_DIR:-locs}

# geo_uridecode <string> -- reverse jq's @uri
geo_uridecode () {
	local s=${1//+/ }
	printf '%b' "${s//%/\\x}"
}

# geo_locs_file <ssid_hex>
# Echo the cache file for this SSID under either naming convention, or nothing.
geo_locs_file () {
	local hex=$1 f uri plain
	f="$GEO_LOCS_DIR/$hex.location"
	[ -f "$f" ] && { printf '%s' "$f"; return 0; }

	# An SSID containing a null byte cannot appear in a filename under either of
	# the text conventions, so stop before decoding it. Without this guard bash
	# emits "command substitution: ignored null byte in input" once per lookup;
	# on a real collection that buried the pass's own output under thousands of
	# warnings and made a 30-minute run look like a hang.
	case "$hex" in *00*) return 1 ;; esac

	uri=$(printf '%s' "$hex" | xxd -r -p 2>/dev/null | jq -sRr @uri 2>/dev/null)
	# jq -sRr @uri keeps the trailing newline from the slurp; strip it.
	uri=${uri%\%0A}
	[ -n "$uri" ] && [ -f "$GEO_LOCS_DIR/$uri.location" ] && {
		printf '%s' "$GEO_LOCS_DIR/$uri.location"; return 0; }

	# Plain text needing no escaping.
	plain=$(printf '%s' "$hex" | xxd -r -p 2>/dev/null)
	[ -n "$plain" ] && [ -f "$GEO_LOCS_DIR/$plain.location" ] && {
		printf '%s' "$GEO_LOCS_DIR/$plain.location"; return 0; }

	return 1
}

# geo_import_locs_cache
#
# Every cached WiGLE response is intel that was paid for with an API call, but
# ssid_intel only ever gets rows for SSIDs seen in the current ssid table. A
# collection whose raw frames were pruned, or a cache carried over from another
# capture, leaves responses on disk with nothing pointing at them.
#
# This adds an ssid_intel row for each one, resolving the filename to an
# ssid_hex and validating that reading against the SSIDs inside the file.
geo_import_locs_cache () {
	local dir=${GEO_LOCS_DIR:-locs}
	echo "geo_import_locs_cache start $(date +"%H:%M:%S.%3N")  ($dir)"

	local -A known=()
	while read -r h; do [ -n "$h" ] && known["$h"]=1; done \
		< <(mysql -N probeprint <<< "select ssid_hex from ssid_intel;")

	local f base decoded hexname urihex chosen ssids
	local as_hex=0 as_uri=0 unresolved=0 inserted=0 already=0

	local _sqlf; _sqlf=$(mktemp)
	{
		echo "start transaction;"
		for f in "$dir"/*.location; do
			[ -f "$f" ] || continue
			base=$(basename "$f" .location)

			# The SSIDs WiGLE echoed back, used to decide which reading is right.
			ssids=$(jq -r '[.results[]?.ssid] | unique | .[]' "$f" 2>/dev/null)

			hexname=""
			case "$base" in
				*[!0-9a-fA-F]*) ;;
				?*) [ $(( ${#base} % 2 )) -eq 0 ] && hexname=$(printf '%s' "$base" | tr 'A-F' 'a-f') ;;
			esac

			decoded=$(geo_uridecode "$base")
			urihex=$(printf '%s' "$decoded" | xxd -p 2>/dev/null | tr -d '\n')

			chosen=""
			# Prefer whichever reading the file's own contents corroborate.
			if [ -n "$hexname" ] && printf '%s\n' "$ssids" \
			   | grep -qxF "$(printf '%s' "$hexname" | xxd -r -p 2>/dev/null)"; then
				chosen=$hexname; as_hex=$((as_hex+1))
			elif [ -n "$urihex" ] && printf '%s\n' "$ssids" | grep -qxF "$decoded"; then
				chosen=$urihex; as_uri=$((as_uri+1))
			elif [ -n "$hexname" ]; then
				chosen=$hexname; as_hex=$((as_hex+1))
			elif [ -n "$urihex" ]; then
				chosen=$urihex; as_uri=$((as_uri+1))
			else
				unresolved=$((unresolved+1)); continue
			fi

			if [ -n "${known[$chosen]:-}" ]; then
				already=$((already+1)); continue
			fi
			known["$chosen"]=1
			printf 'insert ignore into ssid_intel (ssid_hex) values ("%s");\n' "$chosen"
			inserted=$((inserted+1))
		done
		echo "commit;"
	} > "$_sqlf"
	mysql probeprint < "$_sqlf"
	rm -f "$_sqlf"

	echo "  cache files read as hex-named  : $as_hex"
	echo "  cache files read as URI-named  : $as_uri"
	echo "  filename unresolvable          : $unresolved"
	echo "  already in ssid_intel          : $already"
	echo "  ssid_intel rows added          : $inserted"
	echo "geo_import_locs_cache stop $(date +"%H:%M:%S.%3N")"
}

# geo_from_wigle_cache
#
# Populate ssid_intel.lat/lon from the responses already sitting in locs/.
# Entirely offline: these files were fetched by an earlier summarize pass, and
# the coordinates in them were previously parsed and discarded.
#
# --- Case sensitivity is the whole game here ---------------------------------
#
# WiGLE's network search is case-INSENSITIVE. Query "MyNet" and the response
# also contains "mynet" and "MYNET" -- which are different networks, owned by
# different people, in different cities. A probe request carries one exact byte
# string, so only a result whose ssid matches exactly is the network the device
# actually asked for. Everything below filters on exact case first, and the
# count of exact matches decides what can be claimed:
#
#   exactly one   the definitive case. One network on earth has this name, so
#                 its coordinates are that AP's. Recorded with
#                 geo_match_count = 1.
#   more than one distinct APs genuinely share the name. A fix is only
#                 meaningful if they cluster; otherwise none is recorded.
#   none          WiGLE knows the name only in other letter cases, which tells
#                 us nothing about this network.
#
# This is why the pass cannot lean on WiGLE's own totalResults: that number
# counts the case-insensitive matches, so a unique name with two case variants
# looks ambiguous, and an ambiguous name whose variants happen to share a case
# looks unique.
geo_from_wigle_cache () {
	local recompute=${1:-}
	local guard="and (lat is null or lon is null)"
	[ "$recompute" = "--recompute" ] && guard=""

	echo "geo_from_wigle_cache start $(date +"%H:%M:%S.%3N")"
	local ssid_hex ssid file matches n lat lon
	local unique=0 clustered=0 ambiguous=0 nomatch=0 skipped=0

	while read -r ssid_hex; do
		[ -z "$ssid_hex" ] && continue
		file=$(geo_locs_file "$ssid_hex") || file=""
		[ -n "$file" ] && [ -f "$file" ] || { skipped=$((skipped+1)); continue; }

		ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null)

		# --arg, not interpolation: an SSID may contain a double quote.
		matches=$(jq -c --arg s "$ssid" \
			'[.results[]? | select(.ssid==$s) | {lat:.trilat, lon:.trilong}
			  | select(.lat != null and .lon != null)]' "$file" 2>/dev/null)
		[ -z "$matches" ] && { skipped=$((skipped+1)); continue; }

		n=$(printf '%s' "$matches" | jq 'length' 2>/dev/null)
		n=${n:-0}

		# Record how many exact-case matches there were even when no fix is
		# possible, so "no coordinates" can be told apart from "not looked at".
		mysql probeprint <<SQL
update ssid_intel set geo_match_count = $n where ssid_hex = "$ssid_hex";
SQL

		if [ "$n" -eq 0 ]; then
			nomatch=$((nomatch+1)); continue
		fi

		if [ "$n" -eq 1 ]; then
			# The definitive case: one network on earth carries this exact name.
			lat=$(printf '%s' "$matches" | jq -r '.[0].lat')
			lon=$(printf '%s' "$matches" | jq -r '.[0].lon')
			mysql probeprint <<SQL
update ssid_intel
   set lat = $lat, lon = $lon, geo_source = 'wigle'
 where ssid_hex = "$ssid_hex";
SQL
			unique=$((unique+1))
			continue
		fi

		# More than one AP genuinely shares this exact name. A coordinate is
		# only defensible if they sit within ~0.01 degrees, roughly 1km -- an
		# enterprise SSID spread over one campus, say. Anything wider has no
		# single location and averaging would invent one.
		#
		# The spread is written as max-of-a-two-element-array rather than with
		# `as` bindings: in jq, `A - B as $v | body` binds `as` to B alone and
		# folds the rest into the body, so the obvious spelling silently
		# computes something else. It scored a single point 171 degrees wide.
		local spread
		spread=$(printf '%s' "$matches" | jq -r '
			[ ((map(.lat)|max) - (map(.lat)|min)),
			  ((map(.lon)|max) - (map(.lon)|min)) ] | max' 2>/dev/null)
		if awk -v s="${spread:-99}" 'BEGIN{exit !(s > 0.01)}'; then
			ambiguous=$((ambiguous+1)); continue
		fi

		lat=$(printf '%s' "$matches" | jq -r '.[0].lat')
		lon=$(printf '%s' "$matches" | jq -r '.[0].lon')
		mysql probeprint <<SQL
update ssid_intel
   set lat = $lat, lon = $lon, geo_source = 'wigle'
 where ssid_hex = "$ssid_hex";
SQL
		clustered=$((clustered+1))
	done <<< "$(mysql -N probeprint <<< "select ssid_hex from ssid_intel where 1=1 $guard;")"

	echo "  unique exact-case match (definitive) : $unique"
	echo "  several exact matches, clustered     : $clustered"
	echo "  several exact matches, too dispersed : $ambiguous"
	echo "  name known only in another case      : $nomatch"
	echo "  no cached WiGLE response             : $skipped"
	echo "geo_from_wigle_cache stop $(date +"%H:%M:%S.%3N")"
}

# ---------------------------------------------------------------------------
# Nominatim: coordinates -> street address.
# ---------------------------------------------------------------------------

# geo_reverse_one <lat> <lon>
# Echoes "house_number,street,city,state,country". Same shape gps2city.sh emits.
geo_reverse_one () {
	local lat=$1 lon=$2 response
	response=$(curl -s --max-time 20 \
		"https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&zoom=18&addressdetails=1" \
		-H "User-Agent: $GEO_USER_AGENT")

	printf '%s' "$response" | jq -r '
		[ (.address.house_number // ""),
		  (.address.road // .address.pedestrian // .address.footway // .address.path // ""),
		  (.address.city // .address.town // .address.village // .address.hamlet // .address.county // ""),
		  (.address.state // ""),
		  (.address.country // "") ] | join(",")' 2>/dev/null
}

# geo_reverse_addresses [limit]
#
# Fill street_address for rows that have coordinates but no address yet.
# Rate limited: OSM's policy is one request per second, and the old gps2city.sh
# loop did not honor it.
geo_reverse_addresses () {
	local limit=${1:-500}
	echo "geo_reverse_addresses start (max $limit, ${GEO_NOMINATIM_SLEEP}s apart)"
	local n=0 ssid_hex lat lon addr

	while IFS='|' read -r ssid_hex lat lon; do
		[ -z "$ssid_hex" ] && continue
		addr=$(geo_reverse_one "$lat" "$lon")
		if [ -n "$addr" ] && [ "$addr" != ",,,," ]; then
			addr=${addr//\'/\'\'}
			mysql probeprint <<SQL
update ssid_intel set street_address = '$addr' where ssid_hex = "$ssid_hex";
SQL
			n=$((n+1))
		fi
		sleep "$GEO_NOMINATIM_SLEEP"
	done <<< "$(mysql -N probeprint <<< "
		select concat_ws('|', ssid_hex, lat, lon)
		  from ssid_intel
		 where lat is not null and lon is not null and street_address is null
		 limit $limit;")"

	echo "  addresses resolved: $n"
}

# ---------------------------------------------------------------------------
# Directed probes -> BSSIDs.
# ---------------------------------------------------------------------------

# geo_harvest_bssids
#
# Pull every non-broadcast destination address out of the capture. These are
# the APs devices asked for by name and address, and the only BSSIDs this
# pipeline ever sees.
geo_harvest_bssids () {
	echo "geo_harvest_bssids start $(date +"%H:%M:%S.%3N")"
	mysql probeprint <<'SQL'
replace into bssid_geo (bssid, ssid_hex, probe_count, first_seen, last_seen,
                        lat, lon, geo_accuracy, geo_source, street_address)
select s.wlan_da,
       substring_index(group_concat(s.ssid_hex order by s.time), ',', 1),
       count(*), min(s.time), max(s.time),
       g.lat, g.lon, g.geo_accuracy, g.geo_source, g.street_address
  from ssid s
  left join bssid_geo g on g.bssid = s.wlan_da
 where s.wlan_da is not null
   and s.wlan_da <> ''
   and s.wlan_da <> 'ff:ff:ff:ff:ff:ff'
 group by s.wlan_da;
SQL
	echo "  directed-probe BSSIDs known: $(mysql -N probeprint <<< 'select count(*) from bssid_geo;')"
	echo "geo_harvest_bssids stop $(date +"%H:%M:%S.%3N")"
}

# geo_google_observer <bssid> [bssid ...]
#
# Ask Google where an observer hearing these APs would be. Note again: this is
# the observer's position, not any single AP's. Google wants two or more APs;
# with one it will usually answer notFound, and considerIp=false stops it
# silently falling back to locating our own egress IP.
geo_google_observer () {
	if [ -z "${GOOGLE_GEOLOCATION_KEY:-}" ]; then
		echo "geo_google_observer: GOOGLE_GEOLOCATION_KEY not set in .env" >&2
		return 1
	fi
	if [ $# -lt 2 ]; then
		echo "geo_google_observer: needs at least 2 BSSIDs to return a useful fix" >&2
		return 1
	fi

	local aps="" b
	for b in "$@"; do
		[ -n "$aps" ] && aps="$aps,"
		aps="$aps{\"macAddress\":\"$b\"}"
	done

	curl -s --max-time 20 -X POST \
		-H 'Content-Type: application/json' \
		-d "{\"considerIp\":false,\"wifiAccessPoints\":[$aps]}" \
		"https://www.googleapis.com/geolocation/v1/geolocate?key=$GOOGLE_GEOLOCATION_KEY" \
	| jq -r 'if .location then
	           [(.location.lat|tostring), (.location.lng|tostring), ((.accuracy // 0)|tostring)] | join(",")
	         else empty end' 2>/dev/null
}

# geo_apple_bssid <bssid>
#
# NOT IMPLEMENTED, deliberately.
#
# Apple's Wi-Fi positioning service is the only one that maps a single BSSID to
# that AP's own coordinates, which is exactly what this pipeline would want.
# But there is no public API: the endpoint at gs-loc.apple.com is undocumented,
# speaks protobuf, and is reachable only by imitating an iOS client. Rye &
# Levin, "Surveilling the Masses with Wi-Fi-Based Positioning Systems" (2024),
# showed a single query returns the positions of hundreds of *unrelated* nearby
# APs, which is what makes it a recognized mass-surveillance vector rather than
# a lookup service.
#
# Using it means imitating a client against an undocumented endpoint and
# receiving location data on third parties who are not part of this engagement.
# That is a decision for the engagement owner, not a default, so this is a stub
# behind GEO_ENABLE_APPLE and there is no implementation behind it.
geo_apple_bssid () {
	if [ "${GEO_ENABLE_APPLE:-0}" != "1" ]; then
		echo "geo_apple_bssid: disabled. Apple exposes no public geolocation API;" >&2
		echo "  the endpoint is undocumented and returns data on unrelated third-party" >&2
		echo "  APs. Set GEO_ENABLE_APPLE=1 only with explicit engagement authorization," >&2
		echo "  and supply an implementation -- none ships here." >&2
		return 1
	fi
	echo "geo_apple_bssid: enabled but not implemented. See the comment above." >&2
	return 1
}

# geo_report
geo_report () {
	echo "=== geolocation coverage ==="
	mysql -N probeprint <<'SQL' | sed 's/^/  /'
select concat('SSIDs with coordinates      : ', count(*)) from ssid_intel where lat is not null;
select concat('  from wigle                : ', count(*)) from ssid_intel where geo_source='wigle';
select concat('  from google               : ', count(*)) from ssid_intel where geo_source='google';
select concat('SSIDs with a street address : ', count(*)) from ssid_intel where street_address is not null;
select concat('directed-probe BSSIDs       : ', count(*)) from bssid_geo;
select concat('  of those, located         : ', count(*)) from bssid_geo where lat is not null;
SQL
}

# geo_definitive
#
# The subset that can be stated as fact: SSIDs with exactly one case-sensitive
# WiGLE match, so the coordinates belong to that specific access point rather
# than to some other network that merely shares the name in a different case.
geo_definitive () {
	printf '%-34s %-11s %-12s %s\n' "ssid" "lat" "lon" "address"
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "%-34s %-11s %-12s %s\n", $1,$2,$3,$4 }'
select substr(unhex(ssid_hex),1,34),
       round(lat,6), round(lon,6),
       ifnull(street_address, ifnull(location,''))
  from ssid_intel
 where geo_match_count = 1 and lat is not null
 order by ssid_hex
 limit 40;
SQL
}
