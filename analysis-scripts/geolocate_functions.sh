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

# geo_cache_index [dir]
#
# Build GEO_CACHE_FILE: ssid_hex -> cache file path, for the whole directory at
# once. Returns 1 if the directory is missing or holds no cache files.
#
# This replaces asking "is there a file for this SSID?" once per row with
# reading the directory once. The old direction was quadratic in the wrong
# variable: geo_locs_file forks xxd and jq to spell the two legacy filename
# conventions, which costs ~11ms and is paid on every MISS -- and a miss is the
# common case, because a corpus has far more SSIDs than WiGLE has been asked
# about. On a real collection that was ~69,000 rows x 11ms = over 13 minutes per
# run, spent almost entirely proving that files do not exist.
#
# Filenames are decoded to hex inside one awk process rather than by forking per
# file. LC_ALL=C makes awk treat bytes as bytes, which matters because SSIDs are
# arbitrary bytes and are routinely not valid UTF-8.
#
# Priority matches the old lookup order: a file literally named with the hex
# wins over one named with the decoded text, so `first write wins` below is
# load-bearing and depends on awk emitting the hex-named entries first.
declare -A GEO_CACHE_FILE
geo_cache_index () {
	local dir=${1:-$GEO_LOCS_DIR}
	GEO_CACHE_FILE=()
	[ -d "$dir" ] || return 1

	local key name
	# -printf '%f' plus a NUL terminator: an SSID may contain a newline, and a
	# line-based read would split such a filename in half.
	while IFS=$'\t' read -r -d '' key name; do
		[ -z "$key" ] && continue
		[ -n "${GEO_CACHE_FILE[$key]:-}" ] && continue
		GEO_CACHE_FILE[$key]="$dir/$name"
	done < <(find "$dir" -maxdepth 1 -name '*.location' -printf '%f\0' 2>/dev/null \
		| LC_ALL=C awk -v RS='\0' -v ORS='\0' '
		BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
		        split("0 1 2 3 4 5 6 7 8 9 a b c d e f", hx, " ") }
		function tohex(s,   out, i, c) {
			out = ""
			for (i = 1; i <= length(s); i++) {
				c = ord[substr(s, i, 1)]
				out = out hx[int(c / 16) + 1] hx[(c % 16) + 1]
			}
			return out
		}
		function uridecode(s,   out, i, c) {
			gsub(/\+/, " ", s)
			out = ""
			for (i = 1; i <= length(s); ) {
				c = substr(s, i, 1)
				if (c == "%" && i + 2 <= length(s)) {
					out = out sprintf("%c", strtonum("0x" substr(s, i + 1, 2)))
					i += 3
				} else { out = out c; i++ }
			}
			return out
		}
		{
			name = $0
			base = name; sub(/\.location$/, "", base)
			# `print`, not `printf`: printf does not append ORS, so a printf here
			# emits every record run together with no NUL between them and the
			# reader sees one enormous unusable field.
			# Pass 1 output: the hex-named convention, which takes precedence.
			if (base ~ /^[0-9a-fA-F]+$/ && length(base) % 2 == 0)
				print tolower(base) "\t" name
			# Pass 2 is deferred to END so every hex-named entry is seen first.
			decoded[++n] = tohex(uridecode(base)) "\t" name
		}
		END { for (i = 1; i <= n; i++) print decoded[i] }
	')

	[ "${#GEO_CACHE_FILE[@]}" -gt 0 ]
}

# geo_locs_file <ssid_hex>
# Echo the cache file for this SSID under either naming convention, or nothing.
#
# Kept as the single-lookup path. geo_from_wigle_cache uses the index above
# instead; this remains correct and is what the index is validated against.
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
	# Null-driven, like every other pass: geo_match_count is set for each row
	# examined -- 0, 1 or more -- so `is null` means "never looked at".
	#
	# Guarding on the coordinates alone could never converge. An SSID WiGLE has
	# no response for can never get a lat, so `lat is null` stays true for it
	# forever and the pass re-examined the whole corpus on every run, at a fixed
	# cost, in exchange for nothing.
	#
	# The consequence to know: re-fetching a response for an SSID already
	# examined does not re-score it, because the row is no longer null. Run
	# --recompute after refreshing the cache for SSIDs already seen.
	local guard="and (lat is null or lon is null) and geo_match_count is null"
	[ "$recompute" = "--recompute" ] && guard=""

	echo "geo_from_wigle_cache start $(date +"%H:%M:%S.%3N")"

	# Read the cache directory once, up front. Refusing here rather than walking
	# the corpus is the difference between a two-second no-op and a quarter-hour
	# one: with GEO_LOCS_DIR pointing somewhere empty -- easily done, since the
	# default is a relative 'locs' that a fresh checkout does not have -- every
	# row still paid a full filename probe to discover nothing was there.
	if ! geo_cache_index; then
		echo "  no cached WiGLE responses under '$GEO_LOCS_DIR' -- nothing to do." >&2
		echo "  Point GEO_LOCS_DIR at the cache, or fetch with ./analysis-scripts/online_wigle_fetch.sh --new." >&2
		echo "geo_from_wigle_cache stop $(date +"%H:%M:%S.%3N")"
		return 0
	fi
	echo "  indexed ${#GEO_CACHE_FILE[@]} cached responses in $GEO_LOCS_DIR"

	local ssid_hex ssid file matches n lat lon
	local unique=0 clustered=0 ambiguous=0 nomatch=0 skipped=0

	while read -r ssid_hex; do
		[ -z "$ssid_hex" ] && continue
		# Hash lookup, not a filename probe. This is the line that used to cost
		# two forks per row.
		file=${GEO_CACHE_FILE[$ssid_hex]:-}
		[ -n "$file" ] && [ -f "$file" ] || { skipped=$((skipped+1)); continue; }

		# An SSID containing a null byte cannot survive command substitution --
		# bash drops the NUL and warns. The decoded string would then be a
		# DIFFERENT SSID from the one probed for, and comparing that against the
		# cache would either miss or, worse, match the wrong network. Refuse
		# instead. geo_locs_file has always guarded this; the loop never had to
		# until the index started resolving these rows to a file.
		case "$ssid_hex" in *00*) skipped=$((skipped+1)); continue ;; esac

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

# derive_is_oneloc [--recompute]
#
# Set ssid_intel.is_oneloc from geo_match_count, which is the same question
# asked correctly.
#
# is_oneloc means "this SSID names exactly one place on earth". It used to be
# computed by grepping the cached WiGLE body for `"totalResults": 1`, but that
# figure counts WiGLE's CASE-INSENSITIVE matches. A genuinely unique network
# reads as ambiguous the moment a differently-cased namesake exists anywhere,
# and an ambiguous name reads as unique whenever its namesakes happen to share
# a case. Measured against geo_match_count on a real collection, most of the
# flag's positives were wrong, in both directions.
#
# The error did not stay in the flag: is_oneloc=1 is what marks an SSID as
# naming one place, so a wrong verdict propagated into every consumer that
# treats such an SSID as a location -- display.sh's places line among them.
#
# geo_match_count counts results matching the probed SSID byte-for-byte, which
# is the actual question -- a probe request carries one exact string.
derive_is_oneloc () {
	local recompute=${1:-}
	local guard="and is_oneloc is null"
	local recompute_clear=""
	if [ "$recompute" = "--recompute" ]; then
		guard=""
		# An unscored row is one WiGLE has never been asked about, so the
		# honest answer is "don't know". Anything sitting there now was
		# written by the totalResults heuristic, and leaving it in place
		# would keep exactly the verdicts this pass exists to retract --
		# on the rows with the least evidence behind them.
		recompute_clear="update ssid_intel set is_oneloc = null where geo_match_count is null;"
	fi

	echo "derive_is_oneloc start $(date +"%H:%M:%S.%3N")"

	# Refuse rather than guess. Falling back to the old heuristic when
	# geolocation has not run would silently reintroduce exactly the bug this
	# replaces, and the caller would have no way to tell.
	local scored
	scored=$(mysql -N probeprint <<< "select count(*) from ssid_intel where geo_match_count is not null;")
	if [ "${scored:-0}" -eq 0 ]; then
		echo "  geo_match_count is unpopulated -- run ./analysis-scripts/geolocate.sh first." >&2
		echo "  Refusing to fall back to the totalResults heuristic: it counts" >&2
		echo "  case-insensitively and was wrong for most of its positives." >&2
		return 1
	fi

	mysql probeprint <<SQL
update ssid_intel
   set is_oneloc = case when geo_match_count = 1 then 1 else 0 end
 where geo_match_count is not null
   $guard;
$recompute_clear

-- Give the definitive ones a location string if nothing else has. Sourced from
-- the coordinates this pass already resolved rather than by re-parsing the
-- cache, so the two can never disagree. location is varchar(64).
update ssid_intel
   set location = left(coalesce(nullif(street_address,''),
                                concat(round(lat,5), ',', round(lon,5))), 64)
 where is_oneloc = 1
   and (location is null or location in ('0','no file','no results','no match for ssid'))
   and (street_address is not null or lat is not null);
SQL

	echo "  definitive (one exact-case match) : $(mysql -N probeprint <<< "select count(*) from ssid_intel where is_oneloc=1;")"
	echo "  not a single place                : $(mysql -N probeprint <<< "select count(*) from ssid_intel where is_oneloc=0;")"
	echo "  undetermined (no cached response) : $(mysql -N probeprint <<< "select count(*) from ssid_intel where is_oneloc is null;")"
	echo "derive_is_oneloc stop $(date +"%H:%M:%S.%3N")"
}

# ---------------------------------------------------------------------------
# WiGLE, from the bulk exports. No network access.
# ---------------------------------------------------------------------------
#
# The offline counterpart to the locs/ cache above. Where that cache is per-SSID
# JSON fetched from the WiGLE API, these are the raw wardrive files the WiGLE
# phone app writes (WigleWifi_*.csv[.gz]) -- the same observations, in bulk,
# needing no API call and no quota. One export covers wherever the operator has
# driven; the API covers the world. They complement each other, so this runs as
# a peer provider and records geo_source='wigle_csv' to keep the two apart.
#
# WIGLE_CSV_DIR points at the exports, exactly as GEO_LOCS_DIR points at the
# cache: a relative default the operator overrides in .env or on the command
# line (./analysis-scripts/geolocate.sh --csv <dir>).
WIGLE_CSV_DIR=${WIGLE_CSV_DIR:-wigle_csv}

# geo_wigle_csv_index [dir]
#
# Parse every WigleWifi_*.csv[.gz] export under `dir` into the wigle_import
# table -- one row per WIFI observation as (ssid_hex, bssid, lat, lon). Rebuilt
# from scratch each call (truncate then load), so it is idempotent. Returns 1
# if the directory holds no exports.
#
# The WiGLE CSV has a fixed 14-column layout after a one-line app-info preamble:
#   MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,Lat,Lon,Alt,Acc,RCOIs,
#   MfgrId,Type
# An SSID may contain a comma, which would shift every column after it if fields
# were counted from the left. They are counted from the RIGHT instead -- Type is
# the last field, Lon the sixth-from-last, Lat the seventh -- so a comma inside
# the SSID never moves the coordinate columns. The SSID is then whatever lies
# between column 2 and the fixed trailing block, rejoined.
#
# The SSID is hex-encoded in awk with the same byte->lowercase-hex scheme the
# rest of the pipeline uses, so the join to ssid_intel.ssid_hex below is exact
# both in bytes and in case for free -- no separate case handling, unlike the
# API path, because the API returns case-insensitive matches and a raw export
# does not. LC_ALL=C so awk treats SSID bytes as bytes; SSIDs are routinely not
# valid UTF-8.
geo_wigle_csv_index () {
	local dir=${1:-$WIGLE_CSV_DIR}
	[ -d "$dir" ] || { echo "  no such directory: $dir" >&2; return 1; }

	local -a files=()
	local f
	for f in "$dir"/WigleWifi_*.csv "$dir"/WigleWifi_*.csv.gz; do
		[ -f "$f" ] && files+=("$f")
	done
	[ "${#files[@]}" -gt 0 ] || { echo "  no WigleWifi_*.csv[.gz] under $dir" >&2; return 1; }
	echo "  indexing ${#files[@]} WiGLE export(s) from $dir"

	mysql probeprint <<'SQL'
create table if not exists wigle_import (
  ssid_hex varchar(255),
  bssid    varchar(17),
  lat      double,
  lon      double,
  key idx_wigle_ssid  (ssid_hex),
  key idx_wigle_bssid (bssid)
) character set utf8mb4 collate utf8mb4_general_ci;
truncate table wigle_import;
SQL

	# Decompress .gz, cat the rest, all into one awk pass that emits batched
	# INSERTs (the seqgraph pattern: far fewer statements than one INSERT/row).
	{
		for f in "${files[@]}"; do
			case "$f" in
				*.gz) gzip -dc -- "$f" 2>/dev/null ;;
				*)    cat -- "$f" ;;
			esac
		done
	} | LC_ALL=C awk '
	BEGIN {
		FS = ","
		for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
		split("0 1 2 3 4 5 6 7 8 9 a b c d e f", hx, " ")
		batch = 0
	}
	function tohex(s,   out, i, c) {
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = ord[substr(s, i, 1)]
			out = out hx[int(c / 16) + 1] hx[(c % 16) + 1]
		}
		return out
	}
	{ sub(/\r$/, "") }                 # WiGLE app exports are CRLF
	$NF != "WIFI" { next }             # WIFI rows only; also skips both header lines
	NF >= 14 {
		mac = $1
		lat = $(NF - 6); lon = $(NF - 5)
		# The SSID is always hex-encoded below, so it cannot inject anything into
		# the INSERT. mac and lat/lon are emitted raw, though, so a corrupt export
		# line -- WiGLE files do contain the occasional garbage row, some carrying
		# a raw NUL byte that MySQL rejects outright -- must be shape-checked here.
		# A real MAC is hex and colons; a real coordinate is a decimal number.
		if (mac !~ /^[0-9a-fA-F:]+$/) next
		if (lat !~ /^-?[0-9]+\.?[0-9]*$/) next
		if (lon !~ /^-?[0-9]+\.?[0-9]*$/) next
		# SSID is columns 2 .. NF-12, rejoined (a comma inside it survives).
		ssid = $2
		for (i = 3; i <= NF - 12; i++) ssid = ssid FS $i
		if (ssid == "") next           # hidden/wildcard export row: nothing to key on
		if (batch % 1000 == 0) {
			if (batch > 0) print ";"
			printf "insert into wigle_import (ssid_hex,bssid,lat,lon) values "
		} else printf ","
		printf "(\"%s\",\"%s\",%s,%s)", tohex(ssid), mac, lat, lon
		batch++
	}
	END { if (batch > 0) print ";" }
	' | mysql probeprint

	local n
	n=$(mysql -N probeprint <<< "select count(*) from wigle_import;")
	echo "  loaded $n WIFI observation(s)"
	[ "${n:-0}" -gt 0 ]
}

# geo_from_wigle_csv [--recompute] [dir]
#
# Resolve ssid_intel coordinates (and directed-probe BSSIDs in bssid_geo) from
# the local WiGLE exports, entirely offline. Same resolution rules as
# geo_from_wigle_cache: count the distinct access points carrying the exact
# name, and record a fix only when they name one place, or cluster within
# ~0.01 degrees (~1km). Recorded as geo_source='wigle_csv'.
#
# geo_match_count here is the number of distinct BSSIDs with the exact SSID --
# i.e. how many physical APs carry the name in the export. One AP is the
# definitive case, as with the API path's single exact-case result.
#
# CAVEAT on is_oneloc. For the API path geo_match_count=1 means one network on
# EARTH has the name (WiGLE's global database). Here it means one AP has it in
# YOUR export's coverage -- a weaker claim. Read a wigle_csv oneloc as "unique
# within the wardriven area", not globally unique.
geo_from_wigle_csv () {
	local recompute="" import="" dir="" a
	for a in "$@"; do
		case "$a" in
			--recompute) recompute=1 ;;
			--import)    import=1 ;;
			*)           dir=$a ;;
		esac
	done

	echo "geo_from_wigle_csv start $(date +"%H:%M:%S.%3N")"

	if ! geo_wigle_csv_index "${dir:-$WIGLE_CSV_DIR}"; then
		echo "  no WiGLE exports to index -- point WIGLE_CSV_DIR (or the --csv arg)"
		echo "  at a directory of WigleWifi_*.csv[.gz] files."
		echo "geo_from_wigle_csv stop $(date +"%H:%M:%S.%3N")"
		return 0
	fi

	# --import: seed ssid_intel with the export SSIDs that actually resolve to a
	# place, so an SSID wardriven but never (yet) probed for is still on file with
	# its coordinates. This is the CSV analogue of geo_import_locs_cache, and the
	# same reasoning: an export is intel worth keeping even when nothing in the
	# current capture points at it. Only the locatable ones are loaded -- a
	# dispersed common name like xfinitywifi would add a bare, locationless row.
	# The UPDATE below then fills the coordinates for these new rows too, since
	# they arrive with a null lat and satisfy the incremental guard.
	if [ -n "$import" ]; then
		mysql probeprint <<'SQL'
insert ignore into ssid_intel (ssid_hex)
select ssid_hex from (
    select ssid_hex,
           count(distinct bssid) as ap_count,
           (max(lat) - min(lat)) as latsp,
           (max(lon) - min(lon)) as lonsp
      from wigle_import
     group by ssid_hex ) g
 where g.ap_count = 1 or (g.latsp <= 0.01 and g.lonsp <= 0.01);
SQL
	fi

	# Guards mirror geo_from_wigle_cache. Incremental fills only never-examined
	# rows; recompute redoes the rows this provider owns (or that nothing has
	# resolved), never clobbering a more authoritative API 'wigle'/'google' fix.
	local guard="and (si.lat is null or si.lon is null) and si.geo_match_count is null"
	local bguard="and b.lat is null"
	if [ -n "$recompute" ]; then
		guard="and (si.geo_source is null or si.geo_source = 'wigle_csv')"
		bguard="and (b.geo_source is null or b.geo_source = 'wigle_csv')"
	fi

	# The whole SSID resolution in one UPDATE join. The subquery collapses the
	# export to one row per SSID: how many distinct APs carry it, how far they
	# spread, and their centroid. geo_match_count is always recorded; a fix
	# (lat/lon/geo_source) only when one AP carries the name or they cluster.
	mysql probeprint <<SQL
update ssid_intel si
  join ( select ssid_hex,
                count(distinct bssid) as ap_count,
                (max(lat) - min(lat)) as latsp,
                (max(lon) - min(lon)) as lonsp,
                avg(lat) as alat, avg(lon) as alon
           from wigle_import
          group by ssid_hex ) w
    on w.ssid_hex = si.ssid_hex
   set si.geo_match_count = w.ap_count,
       si.lat = case when w.ap_count = 1 or (w.latsp <= 0.01 and w.lonsp <= 0.01)
                     then w.alat else si.lat end,
       si.lon = case when w.ap_count = 1 or (w.latsp <= 0.01 and w.lonsp <= 0.01)
                     then w.alon else si.lon end,
       si.geo_source = case when w.ap_count = 1 or (w.latsp <= 0.01 and w.lonsp <= 0.01)
                     then 'wigle_csv' else si.geo_source end
 where 1=1 $guard;
SQL

	# BSSIDs are the offline path's bonus. An export maps a hardware address
	# straight to a position -- the per-AP lookup no other offline provider can
	# do (WiGLE's SSID search cannot, Google locates the observer, Apple has no
	# public API). A BSSID is one physical AP, so its observations cluster;
	# average them, and record a fix only if they actually do (a roaming/mobile
	# AP with a wandering address would not).
	mysql probeprint <<SQL
update bssid_geo b
  join ( select lower(bssid) as bssid,
                avg(lat) as alat, avg(lon) as alon,
                (max(lat) - min(lat)) as latsp,
                (max(lon) - min(lon)) as lonsp
           from wigle_import
          group by lower(bssid) ) w
    on w.bssid = lower(b.bssid)
   set b.lat = w.alat, b.lon = w.alon, b.geo_source = 'wigle_csv'
 where w.latsp <= 0.01 and w.lonsp <= 0.01 $bguard;
SQL

	echo "  SSIDs fixed from exports  : $(mysql -N probeprint <<< "select count(*) from ssid_intel where geo_source='wigle_csv';")"
	echo "  BSSIDs fixed from exports : $(mysql -N probeprint <<< "select count(*) from bssid_geo where geo_source='wigle_csv';")"
	echo "geo_from_wigle_csv stop $(date +"%H:%M:%S.%3N")"
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

check_oneloc () {
	#set -x
	# The body of this pass now lives in geolocate_functions.sh as
	# derive_is_oneloc, sourced at the top of this file, so the two generations
	# of the codebase cannot drift apart on it.
	#
	# It used to grep the cached WiGLE body for `"totalResults": 1`. That number
	# counts case-INSENSITIVE matches, so "MyNet" and "mynet" -- different
	# networks, different owners, different cities -- inflated it together, and
	# the flag was wrong for most of its positives in both directions. It is now
	# derived from geo_match_count, which counts results matching the probed
	# SSID byte-for-byte.
	#
	# The old "AMBIGUOUS_LOC" placeholder is gone with it: a row can only reach
	# is_oneloc=1 by having a resolved coordinate, so there is nothing ambiguous
	# left to mark.
	derive_is_oneloc "$@"
}
