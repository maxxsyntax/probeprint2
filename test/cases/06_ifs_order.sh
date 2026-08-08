#!/bin/bash
# IFS must not leak between functions.
#
# ssid_intel_functions.sh is sourced into a single shell, and check_airport and
# mac2vendor both used to set IFS globally with no restore. Whichever ran first
# changed word-splitting for everything after it -- and because mysql -N output
# is tab separated, a leaked IFS='|' made `arr=($row)` swallow an entire row into
# arr[0]. So the same passes in a different order gave different results.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

snapshot () {
    sq "select concat_ws('|',ssid_hex,ifnull(category,'-'),ifnull(is_airport,'-'),ifnull(is_name,'-')) from ssid_intel order by ssid_hex;"
}

# --- order A: airport before vendor before categorize --------------------
reset_db
(
    source ./analysis-scripts/ssid_intel_functions.sh
    ssid2ssid_intel
    check_airport
    mac2vendor
    categorize
) >/tmp/order_a.log 2>&1
snapshot > /tmp/snap_a.txt
vendor_a=$(sq1 "select ifnull(vendor,'-') from ssid where wlan_sa='00:1a:11:00:00:01';")

# --- order B: categorize before vendor before airport --------------------
reset_db
(
    source ./analysis-scripts/ssid_intel_functions.sh
    ssid2ssid_intel
    categorize
    mac2vendor
    check_airport
) >/tmp/order_b.log 2>&1
snapshot > /tmp/snap_b.txt
vendor_b=$(sq1 "select ifnull(vendor,'-') from ssid where wlan_sa='00:1a:11:00:00:01';")

# --- the results must be identical ---------------------------------------
if diff -q /tmp/snap_a.txt /tmp/snap_b.txt >/dev/null 2>&1; then
    pass "enrichment results are independent of pass order"
else
    fail "enrichment results are independent of pass order" \
        "identical ssid_intel state" "$(diff /tmp/snap_a.txt /tmp/snap_b.txt | head -5 | tr '\n' ' ')"
fi

assert_eq "mac2vendor works when it runs after check_airport" "$vendor_b" "$vendor_a"
assert_contains "mac2vendor resolved a real vendor in order A" "Google" "$vendor_a"
assert_contains "mac2vendor resolved a real vendor in order B" "Google" "$vendor_b"

# --- IFS is not modified in the caller's shell ---------------------------
# Sourcing the functions and running them must leave IFS at its default.
before=$(printf '%q' "$IFS")
(
    source ./analysis-scripts/ssid_intel_functions.sh
    check_airport
) >/dev/null 2>&1
after=$(printf '%q' "$IFS")
assert_eq "IFS unchanged in the calling shell" "$before" "$after"

finish
