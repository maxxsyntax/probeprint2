#!/bin/bash
# Coordinates from the WiGLE cache, and BSSID harvesting from directed probes.
#
# Entirely offline. The default path reads locs/ and makes no network call at
# all, which is the property that lets this run in CI and lets geo_online=1 be
# safe during capture.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
# TooMany has a cached quota-exhausted response but is never probed for in the
# seed, so give it an ssid_intel row -- otherwise the assertion below queries a
# row that does not exist and passes for the wrong reason.
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('TooMany')));"

# --- coordinates are extracted, not discarded -----------------------------
# The pipeline previously parsed country/region/city/road out of these same
# files and threw trilat/trilong away.
./standalone_geolocate.sh >/tmp/geo.log 2>&1

assert_eq "a single-location SSID gets coordinates" "41.86254768,-87.91438916" \
    "$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('OneCity'));")"
assert_eq "and records which provider supplied them" "wigle" \
    "$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('OneCity'));")"

# --- an SSID seen in many places must NOT get a fix -----------------------
# Averaging Chicago, London and Tokyo would invent a coordinate in open ocean.
assert_eq "a multi-country SSID is left without coordinates" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('ManyCountries'));")"
assert_eq "a multi-city SSID is left without coordinates" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('ManyCities'));")"

# --- case sensitivity decides everything ----------------------------------
# WiGLE searches case-insensitively, so a query for "CaseNet" also returns
# "casenet" (Sydney) and "CASENET" (Tokyo) -- different networks entirely. Only
# the exact-case result is the network the probe request asked for, and there is
# exactly one, so its coordinates are definitive.
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values
  (lower(hex('CaseNet'))), (lower(hex('DupExactNet'))), (lower(hex('CampusNet')));"
./standalone_geolocate.sh >/tmp/geo2.log 2>&1

assert_eq "one exact-case match among three yields coordinates" "48.85837009,2.29448128" \
    "$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('CaseNet'));")"
assert_eq "and the other letter cases are not counted as matches" "1" \
    "$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('CaseNet'));")"
assert_eq "the fix is the exact-case entry, not the first result" "1" \
    "$(sq1 "select round(lat) = 49 from ssid_intel where ssid_hex=lower(hex('CaseNet'));")"

# Two results that BOTH match exactly, in different cities: genuinely ambiguous.
assert_eq "two exact matches far apart yield no coordinates" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('DupExactNet'));")"
assert_eq "but the ambiguity is recorded, not silently dropped" "2" \
    "$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('DupExactNet'));")"

# Two exact matches within one campus, plus a differently-cased third that must
# be ignored: close enough to place, so a fix is allowed.
assert_eq "clustered exact matches still yield a fix" "1" \
    "$(sq1 "select lat is not null from ssid_intel where ssid_hex=lower(hex('CampusNet'));")"
assert_eq "the differently-cased entry is excluded from the count" "2" \
    "$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('CampusNet'));")"

# geo_match_count distinguishes "no exact match" from "never examined".
assert_eq "zero exact matches is recorded as 0, not left NULL" "0" \
    "$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('NoResults'));")"

# The definitive set is queryable on its own.
assert_eq "definitive fixes are selectable by geo_match_count = 1" "1" \
    "$(sq1 "select count(*) >= 2 from ssid_intel where geo_match_count = 1 and lat is not null;")"

assert_contains "the run reports the definitive count separately" \
    "unique exact-case match (definitive)" "$(cat /tmp/geo2.log)"

# --- no fix invented where there is no data -------------------------------
assert_eq "an SSID with zero WiGLE results gets no coordinates" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('NoResults'));")"
assert_eq "a quota-exhausted response yields no coordinates" "NULL" \
    "$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('TooMany'));")"

# --- strictly offline ------------------------------------------------------
assert_not_contains "the default path names no network host" \
    "nominatim" "$(cat /tmp/geo.log)"
assert_not_contains "the default path does not call Google" \
    "googleapis" "$(cat /tmp/geo.log)"

# --- idempotent ------------------------------------------------------------
before=$(sq "select ssid_hex,lat,lon from ssid_intel order by ssid_hex;" | md5sum)
./standalone_geolocate.sh >/dev/null 2>&1
assert_eq "re-running changes nothing" "$before" \
    "$(sq "select ssid_hex,lat,lon from ssid_intel order by ssid_hex;" | md5sum)"

# --- directed probes yield BSSIDs -----------------------------------------
./standalone_geolocate.sh --bssids >/tmp/bssid.log 2>&1

assert_eq "two directed-probe BSSIDs harvested" "2" \
    "$(sq1 "select count(*) from bssid_geo;")"
assert_eq "the broadcast address is not treated as a BSSID" "0" \
    "$(sq1 "select count(*) from bssid_geo where bssid='ff:ff:ff:ff:ff:ff';")"
assert_eq "probe counts are recorded per BSSID" "2" \
    "$(sq1 "select probe_count from bssid_geo where bssid='de:ad:be:ef:00:01';")"
assert_eq "the SSID asked for is kept alongside the BSSID" "$(hexof OneCity)" \
    "$(sq1 "select ssid_hex from bssid_geo where bssid='de:ad:be:ef:00:01';")"

# --- Apple stays off unless deliberately enabled --------------------------
source ./geolocate_functions.sh
out=$(geo_apple_bssid de:ad:be:ef:00:01 2>&1); rc=$?
assert_eq "the Apple provider refuses by default" "1" "$rc"
assert_contains "and explains why rather than failing silently" \
    "no public geolocation API" "$out"
assert_contains "and names the authorization it needs" "GEO_ENABLE_APPLE=1" "$out"

# --- Google refuses to guess ----------------------------------------------
out=$(GOOGLE_GEOLOCATION_KEY= geo_google_observer de:ad:be:ef:00:01 2>&1); rc=$?
assert_eq "Google provider refuses without a key" "1" "$rc"
assert_contains "and says which key is missing" "GOOGLE_GEOLOCATION_KEY" "$out"

out=$(GOOGLE_GEOLOCATION_KEY=dummy geo_google_observer de:ad:be:ef:00:01 2>&1); rc=$?
assert_eq "Google provider refuses a single BSSID" "1" "$rc"
assert_contains "and explains it needs two or more" "at least 2 BSSIDs" "$out"

# --- coverage report -------------------------------------------------------
rep=$(./standalone_geolocate.sh --report 2>&1)
assert_contains "report counts located SSIDs" "SSIDs with coordinates" "$rep"
assert_contains "report counts directed-probe BSSIDs" "directed-probe BSSIDs" "$rep"

finish
