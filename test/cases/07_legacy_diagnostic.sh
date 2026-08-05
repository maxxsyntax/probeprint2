#!/bin/bash
# The legacy-row diagnostic must detect shifted rows and must never write.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db

# --- clean data: nothing should be flagged -------------------------------
out=$(./diagnose_legacy_rows.sh 2>&1)
assert_contains "clean fixture data reports no shifted rows" \
    "No evidence of shifted rows" "$out"

# --- inject rows shaped the way the old parser would have written them ----
# An epoch in rssi, a sequence number in freq, and a bare int in vht are what a
# left-shift produces.
mysql probeprint <<'SQL'
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('ShiftedOne')), 'aa:00:00:00:00:aa', '1700009000.000001', '1700009000', 105, null, ''),
  (lower(hex('ShiftedTwo')), 'aa:00:00:00:00:bb', '1700009000.000002', '-50', 9999, 200, '0x03fbfa00'),
  (lower(hex('ShiftedTre')), 'aa:00:00:00:00:cc', '1700009000.000003', '-50', 2437, 70000, '450');
SQL

before_rows=$(sq1 "select count(*) from ssid;")
before_hash=$(sq "select concat_ws('|',ssid_hex,wlan_sa,time,ifnull(rssi,''),ifnull(freq,''),ifnull(seq,''),ifnull(vht,'')) from ssid order by time;" | md5sum)

out=$(./diagnose_legacy_rows.sh 2>&1)

assert_contains "detects an epoch value sitting in rssi" \
    "rssi holds an epoch timestamp" "$out"
assert_contains "reports a non-zero suspect count" "suspect rows: 3" "$out"
assert_contains "explains that shifted rows cannot be repaired in place" \
    "cannot be repaired in place" "$out"

# --- read-only guarantee -------------------------------------------------
after_rows=$(sq1 "select count(*) from ssid;")
after_hash=$(sq "select concat_ws('|',ssid_hex,wlan_sa,time,ifnull(rssi,''),ifnull(freq,''),ifnull(seq,''),ifnull(vht,'')) from ssid order by time;" | md5sum)

assert_eq "diagnostic did not change the row count" "$before_rows" "$after_rows"
assert_eq "diagnostic did not modify any row" "$before_hash" "$after_hash"

# It must also not create or touch the intel tables.
assert_eq "diagnostic wrote nothing to ssid_intel" "0" \
    "$(sq1 "select count(*) from ssid_intel;")"

finish
