#!/bin/bash
# Burst grouping: all three methods must actually produce bursts.
#
# Before the fixes, grouping by MAC failed on a SQL syntax error (a missing
# `and`) and grouping by sequence number returned nothing (`seq!=null` is never
# true), so `bursts` stayed empty no matter how much data was collected.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

source ./bursts_functions.sh
reset_db

# --- grouping by MAC address ---------------------------------------------
ssid_2bursts-wlan_sa >/tmp/burst_mac.log 2>&1

assert_not_contains "wlan_sa pass produced no SQL error" \
    "ERROR" "$(cat /tmp/burst_mac.log)"

# Keyed on this fixture's own burst rather than a global count: other fixtures
# in seed.sql (the sequence-graph rotations) legitimately form bursts too.
BURST_T=1700000200.100000

assert_eq "wlan_sa pass created a burst for the 4-frame MAC" \
    "1" "$(sq1 "select count(*) from bursts where time='$BURST_T' and bmethod='wlan_sa';")"

assert_eq "burst contains all 4 probes from the shared MAC" \
    "4" "$(sq1 "select burst_size from bursts where time='$BURST_T';")"

# All four member SSIDs must appear in the colon-joined ssids column.
ssids=$(sq1 "select ssids from bursts where time='$BURST_T';")
for name in BurstAlpha BurstBravo BurstCharlie BurstDelta; do
    assert_contains "burst ssids include $name" "$(hexof $name)" "$ssids"
done

assert_eq "burst members marked is_processed=100" \
    "4" "$(sq1 "select count(*) from ssid where wlan_sa='0a:00:00:00:00:01' and is_processed=100;")"

assert_eq "burst duration is non-zero" \
    "1" "$(sq1 "select burst_duration+0 > 0 from bursts where time='$BURST_T';")"

# --- grouping by sequence number -----------------------------------------
ssid2bursts-seq >/tmp/burst_seq.log 2>&1

assert_not_contains "seq pass produced no SQL error" \
    "ERROR" "$(cat /tmp/burst_seq.log)"

# The three SeqBurst* rows share an RSSI band and fall inside the +60 sequence
# window, so they group despite having randomized (distinct) MAC addresses.
assert_eq "seq pass created at least one burst" \
    "1" "$(sq1 "select least(count(*),1) from bursts where bmethod='seq';")"

# --- grouping by VHT tag -------------------------------------------------
ssid2bursts-vht >/tmp/burst_vht.log 2>&1

assert_not_contains "vht pass produced no SQL error" \
    "ERROR" "$(cat /tmp/burst_vht.log)"

assert_eq "vht pass created at least one burst" \
    "1" "$(sq1 "select least(count(*),1) from bursts where bmethod='vht';")"

# --- rssi comparison is numeric, not lexicographic -----------------------
# '-42' <= '-40' is false as strings but true as numbers. If the cast were
# missing, no rssi-banded burst could ever form.
assert_eq "negative rssi compares numerically" \
    "1" "$(sq1 "select cast('-42' as signed) <= -40;")"

# --- is_uniq ------------------------------------------------------------
is_uniq >/tmp/burst_uniq.log 2>&1
assert_eq "every burst got an is_uniq verdict" \
    "0" "$(sq1 "select count(*) from bursts where is_uniq is null;")"
assert_eq "the 4-distinct-ssid burst is marked unique" \
    "1" "$(sq1 "select is_uniq from bursts where time='$BURST_T';")"

finish
