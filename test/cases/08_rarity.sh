#!/bin/bash
# Continuous SSID rarity scoring.
#
# The point of this pass is that PNL linkage depends on the rarity of shared
# SSIDs, not their count. A binary common/not-common flag -- which is what
# is_common gives -- throws that signal away.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"

./analysis-scripts/rarity.sh >/tmp/rarity.log 2>&1

# --- the frequency table loaded ------------------------------------------
freq_rows=$(sq1 "select count(*) from ssid_freq;")
assert_eq "ssid_freq loaded the whole list (208028 rows)" "208028" "$freq_rows"

# SSIDs containing a comma must survive the CSV split. " Timber-Guest" is a real
# entry that a naive awk -F, would have truncated.
assert_eq "SSID containing a comma parsed correctly" "250" \
    "$(sq1 "select total from ssid_freq where ssid_hex=lower(hex(' Timber-Guest'));")"

# --- known-common SSID gets a low score ----------------------------------
assert_eq "xfinitywifi total matches the source list" "21816889" \
    "$(sq1 "select ssid_total from ssid_intel where ssid_hex=lower(hex('xfinitywifi'));")"

xfin=$(sq1 "select round(rarity,2) from ssid_intel where ssid_hex=lower(hex('xfinitywifi'));")
assert_eq "the most common SSID scores ~2.83" "2.83" "$xfin"

# --- an SSID absent from the corpus is maximally rare --------------------
# "SingleMacNet" is invented, so it should get ln(corpus).
maxr=$(sq1 "select round(ln(sum(total)),2) from ssid_freq;")
assert_eq "an unseen SSID gets the maximum rarity" "$maxr" \
    "$(sq1 "select round(rarity,2) from ssid_intel where ssid_hex=lower(hex('SingleMacNet'));")"
assert_eq "an unseen SSID records zero sightings" "0" \
    "$(sq1 "select ssid_total from ssid_intel where ssid_hex=lower(hex('SingleMacNet'));")"

# --- the ordering is what matters ----------------------------------------
# A personal SSID must outrank a carrier hotspot; this is the whole point.
assert_eq "a personal SSID is rarer than xfinitywifi" "1" \
    "$(sq1 "select (select rarity from ssid_intel where ssid_hex=lower(hex('SingleMacNet')))
                 > (select rarity from ssid_intel where ssid_hex=lower(hex('xfinitywifi')));")"

# --- rarity is strictly more informative than is_common -------------------
# This is the whole justification for the pass. is_common is 1 for any SSID
# present in lists/ssid.csv, so it cannot distinguish xfinitywifi (21.8M
# sightings) from '010101' (250). Rarity puts them ~11 apart on a log scale.
./analysis-scripts/common.sh >/tmp/common.log 2>&1

assert_eq "xfinitywifi and 010101 are both 'common' to the binary flag" "1,1" \
    "$(sq1 "select concat_ws(',',
              (select is_common from ssid_intel where ssid_hex=lower(hex('xfinitywifi'))),
              (select is_common from ssid_intel where ssid_hex=lower(hex('010101'))));")"

spread=$(sq1 "select round(
              (select rarity from ssid_intel where ssid_hex=lower(hex('010101')))
            - (select rarity from ssid_intel where ssid_hex=lower(hex('xfinitywifi'))), 1);")
assert_eq "but rarity separates them by ~11.4" "11.4" "$spread"

# Every SSID the flag lumps into is_common=1 still gets its own rarity. Asserted
# as a floor rather than an exact count, since which fixture SSIDs happen to
# appear in lists/ssid.csv is a property of the shipped list, not of this code.
assert_eq "'common' SSIDs have distinct rarities" "1" \
    "$(sq1 "select count(distinct rarity) >= 3 from ssid_intel
             where is_common = 1 and rarity is not null;")"

# --- anomalous hex is skipped --------------------------------------------
assert_eq "all-zero ssid_hex gets no rarity score" "NULL" \
    "$(sq1 "select ifnull(rarity,'NULL') from ssid_intel where ssid_hex='000000000000';")"

# --- incremental by default, and idempotent -------------------------------
before=$(sq "select ssid_hex,rarity from ssid_intel order by ssid_hex;" | md5sum)
./analysis-scripts/rarity.sh >/tmp/rarity2.log 2>&1
after=$(sq "select ssid_hex,rarity from ssid_intel order by ssid_hex;" | md5sum)
assert_eq "re-running changes nothing" "$before" "$after"
assert_contains "second run skips reloading the frequency table" \
    "already holds" "$(cat /tmp/rarity2.log)"

finish
