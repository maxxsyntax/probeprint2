#!/bin/bash
# Resolve SSIDs that name a business to that business's street address, via the
# Google Places API.
#
# Why this exists: WiGLE can only place an SSID somebody wardrove. On a real
# collection that is a small minority -- everything else is a name with no
# location attached. But an SSID like "Cafe Marguerite" names a venue, and the
# venue is on the map whether or not anyone ever drove past it with a radio.
#
# WHICH API. Not the Geolocation API that geo_google_observer uses: that takes
# BSSIDs and answers "where is the observer". This is the Places API (New)
# searchText endpoint, which takes a name and answers "where is that venue".
# They are different products with different keys and different billing.
#
# WHAT THE ANSWER MEANS -- read this before trusting a result. WiGLE reports an
# observation: a radio with this SSID was heard at these coordinates. Places
# reports a venue's address, and that only becomes the device's location if the
# SSID really is that venue's network. "Cafe Marguerite" almost certainly is.
# "Starbucks" is not any particular Starbucks, and a household that named its
# router after a favorite restaurant is not at that restaurant. Results are
# written with geo_source='google_places' so this can always be told apart from
# a sighting, and the matching below is deliberately strict to keep the
# obviously-wrong cases out.
#
# THIS PASS SENDS SSIDs TO GOOGLE. That is egress of collected data to a third
# party, and it is billed per request. It is opt-in, capped per run, cached on
# disk so a name is never paid for twice, and deliberately kept out of
# process.sh for the same reason summarize_location.sh is.
#
# Configuration (.env):
#   GOOGLE_PLACES_KEY   API key with the Places API (New) enabled. Required.
#   PLACES_CACHE_DIR    response cache            (default: places)
#   PLACES_SLEEP        seconds between requests  (default: 0.2)
#   PLACES_CATEGORY     narrow candidates to one category. Empty (the default)
#                       means every category the query below does not exclude.

PLACES_CACHE_DIR=${PLACES_CACHE_DIR:-places}
PLACES_SLEEP=${PLACES_SLEEP:-0.2}
PLACES_CATEGORY=${PLACES_CATEGORY:-}
PLACES_ENDPOINT=${PLACES_ENDPOINT:-https://places.googleapis.com/v1/places:searchText}

# places_normalize <string>
#
# Reduce a name to the part worth comparing: lowercase, drop the decoration an
# SSID carries but a venue's name does not, then strip everything that is not a
# letter or digit.
#
# This is what lets "Cafe Marguerite" match the SSID "CafeMarguerite_5G"
# without also letting it match "Tortilleria Alice". The comparison after
# normalization is EXACT -- no edit distance, no substring. Fuzzy matching here
# would invent a location for a real person, which is the one failure mode this
# pass must not have.
#
# Pure parameter expansion, no forks: this runs per candidate.
places_normalize () {
	local s=${1,,}
	# Network decoration, longest first so '2.4ghz' is not left as 'hz'.
	local junk
	for junk in ' - guest' '-guest' '_guest' ' guest' 'guest' \
	            '2.4ghz' '2_4ghz' '24ghz' '5ghz' '2.4g' '5g' '_5' '-5' \
	            'wi-fi' 'wifi' '_wlan' 'wlan' 'network' '_net' \
	            '_ext' '-ext' 'extender' 'free' 'public' 'staff' 'private'; do
		s=${s//"$junk"/}
	done
	s=${s//[^a-z0-9]/}
	printf '%s' "$s"
}

# places_query <string>
#
# The human-readable form actually sent to Google's searchText. An SSID uses
# '-', '_' and '.' where a venue name uses spaces ("188-Family-Medical-Center"),
# so those become spaces -- searchText matches "188 Family Medical Center" far
# better than the raw token or the space-less normalized key. Case is preserved
# (Google is case-insensitive, and the original reads better in --dry-run), and
# runs of whitespace are collapsed.
#
# This is only the query text. The result is still verified with the exact
# places_normalize comparison, so a fuzzier query cannot loosen what is accepted.
places_query () {
	local s=$1
	s=${s//[-_.]/ }                     # separators -> spaces
	while [[ "$s" == *"  "* ]]; do s=${s//  / }; done   # collapse runs
	s=${s# }; s=${s% }                  # trim
	printf '%s' "$s"
}

# places_candidate_sql <limit>
#
# The candidate query, in one place so --dry-run cannot drift from the pass.
#
# Categories are used to exclude, not to include. The obvious-looking
# "category = 'LOCATION_SPECIFIC'" is wrong: check_address() assigns that on the
# shape ^[0-9]{1,5} [A-Z]..., so it holds STREET ADDRESSES -- "1190 Lowell" --
# and not named venues at all. A venue like "Cafe Marguerite" matches no
# keyword list and lands in whatever the catch-all is. So the SQL drops the
# categories that certainly are not businesses, and places_reject() judges the
# rest on shape.
#
# PLACES_CATEGORY, when set, narrows to a single category on top of this.
places_candidate_sql () {
	local limit=$1 narrow=""
	[ -n "${PLACES_CATEGORY:-}" ] && narrow="and category = '$PLACES_CATEGORY'"
	cat <<SQL
select concat_ws('|', ssid_hex, convert(unhex(ssid_hex) using utf8mb4))
  from ssid_intel
 where lat is null
   and lon is null
   and place_match_count is null
   and ssid_hex not like '%00%'
   and (is_common is null or is_common = 0)
   -- check_name already identified these as somebody's personal or family
   -- name. A household is not a business, and asking Google about a surname
   -- returns whatever venue happens to share it.
   and (is_name is null or is_name in ('0',''))
   -- check_airport already placed these at a named airport (an IATA code in the
   -- SSID, e.g. "SJO Free Wifi"). The location is known; paying Google to look
   -- up "SJO Free Wifi by Samsung" as a business is wasted and returns noise.
   and (is_airport is null or is_airport in ('0',''))
   and (category is null or category not in (
        'OTHER_ANOMALOUS','OTHER_NUMERIC','LOCATION_SPECIFIC',
        'TECH_CPE','TECH_PHONE','TECH_PRINTER','TECH_OTHER',
        'TECH_GUEST','TECH_IOT'))
   $narrow
 limit $limit;
SQL
}

# places_reject <ssid>
#
# Print why this SSID is not worth a paid request, or nothing to accept it.
#
# Every request costs money and sends a name to Google, so the bar is "could
# this plausibly be a business Google has heard of". The rules below were
# written against the actual corpus, not guessed; the counts each one removes
# are visible in --dry-run.
#
# Single source of truth: both the pass and --dry-run call this, so what
# --dry-run promises is exactly what the pass does.
places_reject () {
	local ssid=$1 norm lower digits letters
	lower=${ssid,,}
	norm=$(places_normalize "$ssid")

	# A street address, not a venue. check_address() categorizes these as
	# LOCATION_SPECIFIC. Places text search on "1190 Lowell" returns the
	# address, not a business, and without a city it is ambiguous anyway --
	# there are hundreds of 1190 Lowells.
	case "$ssid" in
		[0-9]*)
			if [[ "$ssid" =~ ^[0-9]{1,5}\ ?[A-Za-z] ]]; then
				printf 'street address'; return 0
			fi
			;;
	esac

	if [ ${#norm} -lt 5 ]; then printf 'too short'; return 0; fi

	# Router and carrier defaults. These name a device, not a place, and any
	# match Google returns for them is coincidence.
	local d
	for d in dlink d-link netgear linksys tplink tp-link asus orbi eero belkin \
	         zyxel arris technicolor sagemcom fritz xfinity spectrum attwifi \
	         verizon vodafone movistar telekom bthub skyfi virginmedia \
	         tenda mercusys totolink mikrotik ubiquiti ubnt keenetic sercomm \
	         hitron actiontec calix humax askey huawei honor redmi xiaomi \
	         repeater extender setup androidap iphone galaxy; do
		case "$lower" in *"$d"*) printf 'router default'; return 0 ;; esac
	done

	# Mostly digits: a unit number, a phone number, a serial. Not a name.
	digits=${norm//[^0-9]/}
	if [ ${#digits} -ge $(( ${#norm} / 2 )) ]; then printf 'mostly digits'; return 0; fi

	# No vowel in the alphabetic part. Real venue names have vowels; strings
	# like 'CptnC' and hex fragments do not, and they cannot be looked up.
	letters=${norm//[^a-z]/}
	case "$letters" in
		*[aeiou]*) ;;
		*) printf 'no vowel'; return 0 ;;
	esac

	# Opt-in: require more than one word. Measured on this corpus it removes
	# about 45% of what survives the rules above -- household nicknames like
	# 'roro_o_O' are single tokens, venue names usually are not. It is OFF by
	# default because it also drops genuine one-word businesses, and losing
	# those defeats the point of the pass. Turn it on when the budget matters
	# more than the recall.
	if [ "${PLACES_REQUIRE_MULTIWORD:-0}" = "1" ]; then
		if [[ ! "$ssid" =~ [[:space:]_.-][A-Za-z] ]]; then
			printf 'single word'; return 0
		fi
	fi

	return 1
}

# places_cache_file <ssid_hex>
places_cache_file () {
	printf '%s/%s.json' "$PLACES_CACHE_DIR" "$1"
}

# places_fetch <ssid_hex> <ssid>
#
# Ask Google about one name, caching the response. Returns 1 on a transport or
# quota failure and leaves no cache file behind, so the SSID can be retried.
places_fetch () {
	local hex=$1 ssid=$2 file body http
	file=$(places_cache_file "$hex")
	[ -s "$file" ] && return 0

	# jq builds the body so an SSID containing a quote, a backslash or a
	# newline cannot break out of the JSON. Never interpolate an SSID by hand.
	local payload
	payload=$(jq -nc --arg q "$(places_query "$ssid")" '{textQuery:$q, maxResultCount:5}') || return 1

	body=$(curl -sS --max-time 20 -w '\n%{http_code}' \
		-X POST "$PLACES_ENDPOINT" \
		-H "Content-Type: application/json" \
		-H "X-Goog-Api-Key: $GOOGLE_PLACES_KEY" \
		-H "X-Goog-FieldMask: places.displayName,places.formattedAddress,places.location" \
		-d "$payload" 2>/dev/null) || return 1

	http=${body##*$'\n'}
	body=${body%$'\n'*}

	case "$http" in
		200) ;;
		429|403)
			# Quota or key problem. Same discipline as the WiGLE path: stop the
			# run rather than burning the rest of the budget on errors.
			echo "  Google returned HTTP $http -- quota exhausted or key rejected." >&2
			echo "$body" | head -c 300 >&2; echo >&2
			return 2
			;;
		*)
			echo "  HTTP $http for $(printf '%s' "$hex" | xxd -r -p 2>/dev/null | tr -cd '[:print:]')" >&2
			return 1
			;;
	esac

	mkdir -p "$PLACES_CACHE_DIR" 2>/dev/null
	printf '%s' "$body" > "$file"
	return 0
}

# places_resolve [limit]
#
# The pass. Null-driven on place_match_count, so re-running is cheap and only
# picks up rows never asked about.
places_resolve () {
	local limit=${1:-200}

	echo "places_resolve start $(date +"%H:%M:%S.%3N")"

	if [ -z "${GOOGLE_PLACES_KEY:-}" ]; then
		echo "  GOOGLE_PLACES_KEY is not set in .env -- refusing to run." >&2
		echo "  This pass sends SSIDs to Google and is billed per request, so it" >&2
		echo "  will not start without a key deliberately configured." >&2
		return 1
	fi

	mkdir -p "$PLACES_CACHE_DIR" 2>/dev/null

	local hex ssid norm file n cand_name cand_addr cand_lat cand_lon
	local asked=0 definitive=0 ambiguous=0 nomatch=0 skipped=0 cached=0 rc

	# Candidates: named a place, and WiGLE could not place it. The lat/lon test
	# is the point -- an SSID already carrying an observed fix does not need an
	# inferred one, and paying Google for it would be worse than useless because
	# a Places answer could overwrite a measurement with a guess.
	while IFS='|' read -r hex ssid; do
		[ -z "$hex" ] && continue

		norm=$(places_normalize "$ssid")
		local why
		if why=$(places_reject "$ssid"); then
			# Recorded as 0 rather than left null, so the next run does not
			# reconsider a name already judged not worth asking about.
			skipped=$((skipped+1))
			mysql probeprint <<< "update ssid_intel set place_match_count = 0 where ssid_hex = \"$hex\";"
			continue
		fi

		file=$(places_cache_file "$hex")
		local was_cached=0
		[ -s "$file" ] && { was_cached=1; cached=$((cached+1)); }

		places_fetch "$hex" "$ssid"; rc=$?
		if [ "$rc" -eq 2 ]; then
			echo "  stopping early; $asked request(s) sent this run." >&2
			break
		fi
		[ "$rc" -ne 0 ] && { skipped=$((skipped+1)); continue; }
		[ "$was_cached" -eq 0 ] && asked=$((asked+1))

		# Keep only candidates whose name normalizes to the same string.
		local matches
		matches=$(jq -c --arg n "$norm" '
			[ .places[]?
			  | { name:  (.displayName.text // ""),
			      addr:  (.formattedAddress // ""),
			      lat:   (.location.latitude // null),
			      lon:   (.location.longitude // null) }
			  | select(.lat != null and .lon != null)
			  | select((.name | ascii_downcase | gsub("[^a-z0-9]";"")) == $n) ]' \
			"$file" 2>/dev/null)
		[ -z "$matches" ] && matches='[]'
		n=$(printf '%s' "$matches" | jq 'length' 2>/dev/null); n=${n:-0}

		mysql probeprint <<< "update ssid_intel set place_match_count = $n where ssid_hex = \"$hex\";"

		if [ "$n" -eq 0 ]; then
			nomatch=$((nomatch+1))
		elif [ "$n" -eq 1 ]; then
			cand_name=$(printf '%s' "$matches" | jq -r '.[0].name')
			cand_addr=$(printf '%s' "$matches" | jq -r '.[0].addr')
			cand_lat=$(printf '%s' "$matches" | jq -r '.[0].lat')
			cand_lon=$(printf '%s' "$matches" | jq -r '.[0].lon')
			mysql probeprint <<SQL
update ssid_intel
   set lat = $cand_lat, lon = $cand_lon,
       geo_source = 'google_places',
       street_address = left($(places_sqlquote "$cand_addr"), 255),
       place_name     = left($(places_sqlquote "$cand_name"), 128)
 where ssid_hex = "$hex"
   and lat is null;
SQL
			definitive=$((definitive+1))
		else
			# Several venues share the name. Same rule as the WiGLE path: a fix
			# is only defensible if they sit close together, otherwise there is
			# no single answer and averaging would invent one.
			local spread
			spread=$(printf '%s' "$matches" | jq -r '
				[ ((map(.lat)|max) - (map(.lat)|min)),
				  ((map(.lon)|max) - (map(.lon)|min)) ] | max' 2>/dev/null)
			if awk -v s="${spread:-99}" 'BEGIN{exit !(s > 0.01)}'; then
				ambiguous=$((ambiguous+1))
			else
				cand_name=$(printf '%s' "$matches" | jq -r '.[0].name')
				cand_addr=$(printf '%s' "$matches" | jq -r '.[0].addr')
				cand_lat=$(printf '%s' "$matches" | jq -r '.[0].lat')
				cand_lon=$(printf '%s' "$matches" | jq -r '.[0].lon')
				mysql probeprint <<SQL
update ssid_intel
   set lat = $cand_lat, lon = $cand_lon,
       geo_source = 'google_places',
       street_address = left($(places_sqlquote "$cand_addr"), 255),
       place_name     = left($(places_sqlquote "$cand_name"), 128)
 where ssid_hex = "$hex"
   and lat is null;
SQL
				definitive=$((definitive+1))
			fi
		fi

		# Rate limit only when a request actually went out. Sleeping on a cache
		# hit would make a re-run as slow as the first, for no reason.
		[ "$was_cached" -eq 0 ] && sleep "$PLACES_SLEEP"
	done <<< "$(places_candidate_sql "$limit" | mysql -N probeprint)"

	echo "  requests sent to Google       : $asked"
	echo "  answered from the local cache : $cached"
	echo "  placed (one venue, exact name): $definitive"
	echo "  several venues, too dispersed : $ambiguous"
	echo "  no name match                 : $nomatch"
	echo "  too short or failed           : $skipped"
	echo "places_resolve stop $(date +"%H:%M:%S.%3N")"
}

# places_sqlquote <string> -- a quoted SQL literal, with quotes and backslashes
# escaped. Addresses come from Google and routinely contain apostrophes.
places_sqlquote () {
	local s=${1//\\/\\\\}
	s=${s//\'/\\\'}
	printf "'%s'" "$s"
}

places_report () {
	echo "=== Google Places coverage ==="
	mysql probeprint <<'SQL' | sed 's/^/  /'
select concat('candidates in scope      : ', count(*)) from ssid_intel
   where category = 'LOCATION_SPECIFIC'
union all select concat('  never queried          : ', count(*)) from ssid_intel
   where category = 'LOCATION_SPECIFIC' and place_match_count is null
union all select concat('placed by Places         : ', count(*)) from ssid_intel
   where geo_source = 'google_places'
union all select concat('  with a street address  : ', count(*)) from ssid_intel
   where geo_source = 'google_places' and street_address is not null
union all select concat('asked, nothing matched   : ', count(*)) from ssid_intel
   where place_match_count = 0
union all select concat('placed by WiGLE (sighted): ', count(*)) from ssid_intel
   where geo_source = 'wigle';
SQL
}
