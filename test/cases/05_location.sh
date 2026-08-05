#!/bin/bash
# WiGLE location summarisation, entirely offline against canned API bodies.
#
# No test here may make a network call: locs/ is pre-populated by the
# entrypoint, so wigle_fetch's `[ ! -f "$file" ]` guard short-circuits and curl
# is never reached. .env also sets online=0 and a dummy APIKEY.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"

source ./location_functions.sh

# --- single city: report region + city + road ----------------------------
summarize_one "$(hexof OneCity)" >/dev/null 2>&1
loc=$(sq1 "select location from ssid_intel where ssid_hex=lower(hex('OneCity'));")
assert_contains "single-result SSID reports its city" "Chicago" "$loc"
assert_contains "single-result SSID reports its region" "IL" "$loc"

# --- several cities in one region ----------------------------------------
summarize_one "$(hexof ManyCities)" >/dev/null 2>&1
loc=$(sq1 "select location from ssid_intel where ssid_hex=lower(hex('ManyCities'));")
assert_contains "multi-city SSID reports a city count" "cities" "$loc"

# --- several countries ---------------------------------------------------
summarize_one "$(hexof ManyCountries)" >/dev/null 2>&1
loc=$(sq1 "select location from ssid_intel where ssid_hex=lower(hex('ManyCountries'));")
assert_contains "multi-country SSID reports a country count" "countries" "$loc"

# --- zero results --------------------------------------------------------
summarize_one "$(hexof NoResults)" >/dev/null 2>&1
assert_eq "SSID with no WiGLE hits is marked 'no results'" "no results" \
    "$(sq1 "select location from ssid_intel where ssid_hex=lower(hex('NoResults'));")"

# --- quota exhaustion ----------------------------------------------------
# A "too many queries" body is not a result and must not be written as one.
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values ('$(hexof TooMany)');"
summarize_one "$(hexof TooMany)" >/tmp/quota.log 2>&1
assert_eq "quota-exhausted response leaves location NULL" "NULL" \
    "$(sq1 "select ifnull(location,'NULL') from ssid_intel where ssid_hex=lower(hex('TooMany'));")"

# --- no cached file ------------------------------------------------------
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values ('$(hexof NeverFetched)');"
summarize_one "$(hexof NeverFetched)" >/dev/null 2>&1
assert_eq "uncached SSID is marked 'no file'" "no file" \
    "$(sq1 "select location from ssid_intel where ssid_hex=lower(hex('NeverFetched'));")"

# --- jq injection via an SSID containing a double quote -------------------
# summarize_one must use jq --arg; interpolating the SSID into the jq program
# would make this an invalid program rather than a clean "no match".
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values ('$(hexof 'He said "hi"')');"
cp test/fixtures/locs/"$(hexof OneCity)".location "locs/$(hexof 'He said "hi"').location"
out=$(summarize_one "$(hexof 'He said "hi"')" 2>&1)
assert_not_contains "SSID with a quote does not break the jq program" "error" "$out"
assert_not_contains "SSID with a quote does not produce a jq syntax error" "syntax" "$out"

# --- the bulk sweep writes to the database -------------------------------
# The old summarize_location.sh computed a locale and discarded it, because both
# its DB writes and its bottom-of-file calls were commented out.
mysql probeprint -e "update ssid_intel set location=null;"
./standalone_summarize_loc.sh >/tmp/sweep.log 2>&1
# Every row gets a verdict except the quota-exhausted one, which is deliberately
# left NULL so a later run retries it rather than caching a failure as a result.
assert_eq "bulk sweep resolves everything except the quota row" "1" \
    "$(sq1 "select count(*) from ssid_intel where location is null;")"
assert_eq "the one unresolved row is the quota-exhausted SSID" "$(hexof TooMany)" \
    "$(sq1 "select ssid_hex from ssid_intel where location is null;")"
assert_eq "bulk sweep actually wrote Chicago" "1" \
    "$(sq1 "select count(*) from ssid_intel where location like '%Chicago%';")"

finish
