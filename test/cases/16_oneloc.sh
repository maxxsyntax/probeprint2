#!/bin/bash
# is_oneloc: "this SSID names exactly one place on earth".
#
# The flag used to come from grepping the cached WiGLE body for
# `"totalResults": 1`. WiGLE searches case-INSENSITIVELY, so that number counts
# networks the probe request never asked for. It was wrong in BOTH directions,
# and both directions are asserted here against fixtures:
#
#   CaseNet   totalResults 3, one exact-case match  -> old said 0, truth is 1
#   SoloCase  totalResults 1, zero exact matches    -> old said 1, truth is 0
#
# It is now derived from geo_match_count, which counts byte-for-byte matches --
# the actual question, since a probe request carries one exact string.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values
  (lower(hex('CaseNet'))), (lower(hex('SoloCase'))), (lower(hex('DupExactNet'))),
  (lower(hex('NoResults'))), (lower(hex('Uncached')));"

# --- it refuses to guess when geolocation has not run ---------------------
# A silent fallback to the old heuristic would reintroduce the same error with
# no way for the caller to notice, so the pass fails loudly instead.
out=$(./analysis-scripts/oneloc.sh 2>&1); rc=$?
assert_eq "the pass fails when geo_match_count is unpopulated" "1" "$rc"
assert_contains "and names the pass that must run first" \
    "analysis-scripts/geolocate.sh" "$out"
assert_contains "and says why it will not fall back" "case-insensitively" "$out"
assert_eq "no row is decided by the refused run" "0" \
    "$(sq1 "select count(*) from ssid_intel where is_oneloc is not null;")"

# --- derived from exact-case matches --------------------------------------
./analysis-scripts/geolocate.sh >/tmp/oneloc_geo.log 2>&1
./analysis-scripts/oneloc.sh >/tmp/oneloc.log 2>&1

assert_eq "a single exact match is definitive" "1" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('OneCity'));")"

# The direction the old heuristic got backwards: three results, two of them
# different networks that merely share the letters.
assert_eq "one exact match among three letter cases is still definitive" "1" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('CaseNet'));")"

# The other direction: exactly one result, but it is a different network whose
# name happens to match case-insensitively. The probed SSID is placed nowhere.
assert_eq "a lone differently-cased result is not this network" "0" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('SoloCase'));")"
assert_eq "and it is given no location either" "0" \
    "$(sq1 "select count(*) from ssid_intel
             where ssid_hex=lower(hex('SoloCase')) and lat is not null;")"

assert_eq "two exact matches are not one place" "0" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('DupExactNet'));")"
assert_eq "a cached response with no results is not one place" "0" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('NoResults'));")"

# --- undetermined is not the same as false --------------------------------
# An SSID nobody has looked up yet must stay NULL. Calling it 0 would assert
# "this names more than one place", which the pipeline has no evidence for.
assert_eq "an SSID with no cached response stays undecided" "NULL" \
    "$(sq1 "select ifnull(is_oneloc,'NULL') from ssid_intel
             where ssid_hex=lower(hex('Uncached'));")"

# --- the flag and the count can never disagree ----------------------------
assert_eq "is_oneloc agrees with geo_match_count on every scored row" "0" \
    "$(sq1 "select count(*) from ssid_intel
             where geo_match_count is not null
               and is_oneloc <> (geo_match_count = 1);")"
assert_eq "every scored row is decided" "0" \
    "$(sq1 "select count(*) from ssid_intel
             where geo_match_count is not null and is_oneloc is null;")"

# --- the definitive ones get a location string ----------------------------
# Sourced from the coordinates this pass already resolved rather than by
# re-parsing the cache, so the two can never drift apart.
assert_eq "a definitive SSID is given a location" "1" \
    "$(sq1 "select location = concat(round(lat,5),',',round(lon,5))
              from ssid_intel where ssid_hex=lower(hex('OneCity'));")"
assert_eq "and an undetermined one is not" "0" \
    "$(sq1 "select count(*) from ssid_intel
             where ssid_hex=lower(hex('Uncached')) and location is not null;")"

# --- default fills gaps, --recompute overrules ----------------------------
# Same shape as the other enrichment passes: null-driven by default so it can be
# re-run cheaply, with an explicit flag to redo decisions already made.
mysql probeprint -e "update ssid_intel set is_oneloc=0 where ssid_hex=lower(hex('OneCity'));"
./analysis-scripts/oneloc.sh >/dev/null 2>&1
assert_eq "a decision already made is left alone" "0" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('OneCity'));")"
./analysis-scripts/oneloc.sh --recompute >/dev/null 2>&1
assert_eq "--recompute corrects it" "1" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('OneCity'));")"

# --- --recompute retracts verdicts with no evidence behind them -----------
# Rows the old heuristic decided but geolocation has never scored must go back
# to undetermined. Leaving them would preserve exactly the verdicts this pass
# exists to retract, on the rows with the least evidence behind them.
mysql probeprint -e "update ssid_intel set is_oneloc=1 where ssid_hex=lower(hex('Uncached'));"
./analysis-scripts/oneloc.sh >/dev/null 2>&1
assert_eq "the default run does not touch an unscored row" "1" \
    "$(sq1 "select is_oneloc from ssid_intel where ssid_hex=lower(hex('Uncached'));")"
./analysis-scripts/oneloc.sh --recompute >/dev/null 2>&1
assert_eq "--recompute returns an unscored row to undetermined" "NULL" \
    "$(sq1 "select ifnull(is_oneloc,'NULL') from ssid_intel where ssid_hex=lower(hex('Uncached'));")"
assert_eq "no unscored row keeps a verdict after --recompute" "0" \
    "$(sq1 "select count(*) from ssid_intel
             where geo_match_count is null and is_oneloc is not null;")"

# --- idempotent ------------------------------------------------------------
before=$(sq "select ssid_hex,is_oneloc,location from ssid_intel order by ssid_hex;" | md5sum)
./analysis-scripts/oneloc.sh --recompute >/dev/null 2>&1
assert_eq "re-running changes nothing" "$before" \
    "$(sq "select ssid_hex,is_oneloc,location from ssid_intel order by ssid_hex;" | md5sum)"

# --- the report distinguishes the three states ----------------------------
rep=$(cat /tmp/oneloc.log)
assert_contains "the run reports the definitive set" "definitive" "$rep"
assert_contains "and the rows it decided against" "not a single place" "$rep"
assert_contains "and the rows it could not decide" "undetermined" "$rep"

finish
