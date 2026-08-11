#!/bin/bash
# Google Places: an SSID that names a business, resolved to that business's
# address.
#
# Entirely offline. Every response is pre-seeded in the cache so places_fetch
# short-circuits before curl, and PLACES_ENDPOINT points somewhere unroutable
# so a request that did escape would fail the case rather than pass quietly.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"

CACHE=$(mktemp -d)
export PLACES_CACHE_DIR="$CACHE"
export PLACES_ENDPOINT="http://127.0.0.1:1/never"
export PLACES_SLEEP=0
export GOOGLE_PLACES_KEY=dummy-key-for-tests
# Narrow to the seeds. The candidate query is deliberately broad -- it excludes
# categories rather than naming one -- so without this the base fixture's SSIDs
# would consume the per-run cap before the seeded cases were reached. Exercises
# PLACES_CATEGORY at the same time.
export PLACES_CATEGORY=BIZ_EATERY

seed () { # seed <ssid> <json>
    mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('$1')));"
    mysql probeprint -e "update ssid_intel set category='BIZ_EATERY' where ssid_hex=lower(hex('$1'));"
    printf '%s' "$2" > "$CACHE/$(hexof "$1").json"
}

# One venue, name matches exactly once normalized. The definitive case.
seed 'Cafe Marguerite' '{"places":[
  {"displayName":{"text":"Cafe Marguerite"},
   "formattedAddress":"Av. Insurgentes Sur 1234, Mexico City",
   "location":{"latitude":19.36180000,"longitude":-99.17610000}}]}'

# The same venue, as a router actually spells it. Must reach the same place.
seed 'CafeMarguerite_5G' '{"places":[
  {"displayName":{"text":"Cafe Marguerite"},
   "formattedAddress":"Av. Insurgentes Sur 1234, Mexico City",
   "location":{"latitude":19.36180000,"longitude":-99.17610000}}]}'

# Google returns something plausible but differently named. Must NOT be used.
seed 'Tortilleria Alice' '{"places":[
  {"displayName":{"text":"Cafe Marguerite"},
   "formattedAddress":"Av. Insurgentes Sur 1234, Mexico City",
   "location":{"latitude":19.36180000,"longitude":-99.17610000}}]}'

# A chain: many exact-name venues, far apart. No single answer.
seed 'Cafe Dorado' '{"places":[
  {"displayName":{"text":"Cafe Dorado"},"formattedAddress":"Lisbon",
   "location":{"latitude":38.72200000,"longitude":-9.13930000}},
  {"displayName":{"text":"Cafe Dorado"},"formattedAddress":"Bogota",
   "location":{"latitude":4.71100000,"longitude":-74.07210000}}]}'

# Two exact-name venues inside one campus: close enough to place.
seed 'Campus Roastery' '{"places":[
  {"displayName":{"text":"Campus Roastery"},"formattedAddress":"Building A",
   "location":{"latitude":51.75200000,"longitude":-1.25770000}},
  {"displayName":{"text":"Campus Roastery"},"formattedAddress":"Building B",
   "location":{"latitude":51.75280000,"longitude":-1.25810000}}]}'

# Google knows nothing.
seed 'Zzyzx Holdings Ltd' '{"places":[]}'

# Too short to discriminate -- must be refused before a request is spent.
seed 'Bar' '{"places":[{"displayName":{"text":"Bar"},"formattedAddress":"Anywhere",
   "location":{"latitude":1.0,"longitude":1.0}}]}'

./analysis-scripts/online_places.sh 50 >/tmp/places.log 2>&1

# --- the definitive case --------------------------------------------------
assert_eq "an exactly-named venue is placed" "19.3618,-99.1761" \
    "$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('Cafe Marguerite'));")"
assert_eq "and the street address is stored" "Av. Insurgentes Sur 1234, Mexico City" \
    "$(sq1 "select street_address from ssid_intel where ssid_hex=lower(hex('Cafe Marguerite'));")"
assert_eq "and the provenance says it was inferred, not observed" "google_places" \
    "$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('Cafe Marguerite'));")"
assert_eq "and what Google called it is kept" "Cafe Marguerite" \
    "$(sq1 "select place_name from ssid_intel where ssid_hex=lower(hex('Cafe Marguerite'));")"

# --- SSID decoration is stripped before comparing -------------------------
assert_eq "the same venue is found through a router's spelling" "19.3618,-99.1761" \
    "$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('CafeMarguerite_5G'));")"

# --- a near-miss name is refused ------------------------------------------
# The comparison after normalization is exact. Anything looser would invent a
# location for a real person, which is the failure this pass must not have.
assert_eq "a similar but different name is not placed" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('Tortilleria Alice'));")"
assert_eq "and it is recorded as asked-and-unmatched, not left unknown" "0" \
    "$(sq1 "select place_match_count from ssid_intel where ssid_hex=lower(hex('Tortilleria Alice'));")"

# --- a chain name has no single location ----------------------------------
assert_eq "a name shared by distant venues is not placed" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('Cafe Dorado'));")"
assert_eq "but the ambiguity is counted, not discarded" "2" \
    "$(sq1 "select place_match_count from ssid_intel where ssid_hex=lower(hex('Cafe Dorado'));")"

# --- clustered venues are close enough ------------------------------------
assert_eq "venues within a campus still yield a fix" "1" \
    "$(sq1 "select lat is not null from ssid_intel where ssid_hex=lower(hex('Campus Roastery'));")"

# --- nothing found, and nothing invented ----------------------------------
assert_eq "an unknown venue gets no coordinates" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('Zzyzx Holdings Ltd'));")"
assert_eq "and is marked as asked" "0" \
    "$(sq1 "select place_match_count from ssid_intel where ssid_hex=lower(hex('Zzyzx Holdings Ltd'));")"

# --- a too-short name never costs a request -------------------------------
assert_eq "a three-letter name is not placed" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('Bar'));")"

# --- SSIDs WiGLE already placed are never queried -------------------------
# The whole point of the lat/lon guard: an observation outranks an inference,
# and paying to overwrite one with the other would be worse than useless.
mysql probeprint -e "update ssid_intel set lat=41.0, lon=-87.0, geo_source='wigle',
                     category='BIZ_EATERY' where ssid_hex=lower(hex('OneCity'));"
printf '%s' '{"places":[{"displayName":{"text":"OneCity"},"formattedAddress":"Somewhere Else",
   "location":{"latitude":0.0,"longitude":0.0}}]}' > "$CACHE/$(hexof OneCity).json"
./analysis-scripts/online_places.sh 50 >/tmp/places2.log 2>&1

assert_eq "an SSID with observed coordinates keeps them" "41,-87" \
    "$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('OneCity'));")"
assert_eq "and its provenance still says wigle" "wigle" \
    "$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('OneCity'));")"
assert_eq "and it was never queried at all" "NULL" \
    "$(sq1 "select ifnull(place_match_count,'NULL') from ssid_intel where ssid_hex=lower(hex('OneCity'));")"

# --- null-driven and idempotent -------------------------------------------
before=$(sq "select ssid_hex,lat,lon,place_match_count from ssid_intel order by ssid_hex;" | md5sum)
./analysis-scripts/online_places.sh 50 >/tmp/places3.log 2>&1
assert_eq "re-running changes nothing" "$before" \
    "$(sq "select ssid_hex,lat,lon,place_match_count from ssid_intel order by ssid_hex;" | md5sum)"
assert_contains "and sends no further requests" "requests sent to Google       : 0" \
    "$(cat /tmp/places3.log)"

# --- it refuses without a key ---------------------------------------------
# Billed egress of collected data must not start by accident.
out=$(GOOGLE_PLACES_KEY= ./analysis-scripts/online_places.sh 5 2>&1); rc=$?
assert_eq "no key means the pass refuses" "1" "$rc"
assert_contains "and names the variable" "GOOGLE_PLACES_KEY" "$out"
assert_contains "and says why it will not default to running" "billed per request" "$out"

# --- the candidate filter, rule by rule -----------------------------------
# Every request costs money and sends a name to a third party, so each rule is
# asserted individually rather than trusting an aggregate count.
source ./analysis-scripts/places_functions.sh

check_reject () { # check_reject <expected reason|""> <ssid>
    local got
    got=$(places_reject "$2") || got=""
    assert_eq "reject '$2' as ${1:-<accepted>}" "$1" "$got"
}

# Street addresses. check_address() files these as LOCATION_SPECIFIC, and they
# are the single largest group in this corpus. Places text search on them
# returns the address rather than a business, and without a city there are
# hundreds of each.
check_reject 'street address' '1190 Lowell'
check_reject 'street address' '128Oxford'
check_reject 'street address' '111 Avenue G'

# Device names, not places.
check_reject 'router default' 'NETGEAR47'
check_reject 'router default' 'Tenda_5G'
check_reject 'router default' 'MySpectrum Guest'

# Unit numbers, serials, phone numbers.
check_reject 'mostly digits' '5099251212'
check_reject 'too short'     'Bar'
check_reject 'no vowel'      'CptnC'

# Real venue names must survive all of it -- an over-tight filter defeats the
# purpose of the pass.
check_reject '' 'Cafe Marguerite'
check_reject '' 'CafeMarguerite_5G'
check_reject '' 'Campus Roastery'
check_reject '' 'Lenbach'

# The multiword rule is opt-in, and must not fire unless asked for.
check_reject '' 'Lissovoc'
out=$(PLACES_REQUIRE_MULTIWORD=1 places_reject 'Lissovoc')
assert_eq "PLACES_REQUIRE_MULTIWORD rejects a single word" "single word" "$out"
out=$(PLACES_REQUIRE_MULTIWORD=1 places_reject 'Cafe Marguerite')
assert_eq "and still accepts a multi-word venue" "" "$out"

# A rejected name is recorded, not left null, so the next run does not
# reconsider a name already judged not worth asking about.
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('42 Wallaby Way')));"
mysql probeprint -e "update ssid_intel set category='BIZ_EATERY' where ssid_hex=lower(hex('42 Wallaby Way'));"
./analysis-scripts/online_places.sh 50 >/tmp/places4.log 2>&1
assert_eq "a rejected candidate is marked, not left to be reconsidered" "0" \
    "$(sq1 "select place_match_count from ssid_intel where ssid_hex=lower(hex('42 Wallaby Way'));")"
assert_eq "and no request was spent on it" "0" \
    "$(sq1 "select count(*) from ssid_intel where ssid_hex=lower(hex('42 Wallaby Way')) and lat is not null;")"

# --- the query sent to Google uses spaces, not the raw SSID separators -----
# "188-Family-Medical-Center" is a venue with hyphens for spaces; searchText
# matches "188 Family Medical Center" far better. places_query does that, while
# places_normalize (the exact-match key) still collapses both to one string.
assert_eq "separators in the SSID become spaces in the query" \
    "188 Family Medical Center" "$(places_query '188-Family-Medical-Center')"
assert_eq "and the exact-match key stays separator-free" \
    "188familymedicalcenter" "$(places_normalize '188-Family-Medical-Center')"

# --- airports are not sent to Google --------------------------------------
# check_airport already placed these (an IATA code in the SSID). The location
# is known; a paid Places lookup on "SJO Free Wifi by Samsung" is waste + noise.
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('SJO Free Wifi by Samsung')));"
mysql probeprint -e "update ssid_intel
   set category='OTHER_UNKNOWN', lat=null, lon=null, place_match_count=null,
       is_airport='San Jose [Juan Santamaria International], Costa Rica'
 where ssid_hex=lower(hex('SJO Free Wifi by Samsung'));"
out=$(./analysis-scripts/online_places.sh --dry-run 2>&1)
assert_not_contains "an airport-flagged SSID is not a Places candidate" \
    "SJO Free Wifi" "$out"

# --- --dry-run sends nothing ----------------------------------------------
mysql probeprint -e "update ssid_intel set place_match_count=null where ssid_hex=lower(hex('Cafe Dorado'));"
out=$(./analysis-scripts/online_places.sh --dry-run 2>&1)
assert_contains "--dry-run lists what it would ask about" "Cafe Dorado" "$out"
assert_contains "and states plainly that nothing was sent" "Nothing was sent" "$out"
assert_eq "and really did not write anything" "NULL" \
    "$(sq1 "select ifnull(place_match_count,'NULL') from ssid_intel where ssid_hex=lower(hex('Cafe Dorado'));")"

rm -rf "$CACHE"
finish
