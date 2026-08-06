#!/bin/bash
# Display layer: must query MariaDB, not the long-gone sqlite files, and must
# surface device identity and confidence rather than raw SSIDs alone.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
./standalone_seqgraph.sh >/dev/null 2>&1
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
./standalone_rarity.sh   >/dev/null 2>&1

# --- no sqlite left anywhere in the display path -------------------------
# Comments may legitimately mention sqlite3 (the header explains the port), so
# only non-comment lines count as a call.
assert_eq "display_functions.sh makes no sqlite3 calls" "0" \
    "$(grep -v '^[[:space:]]*#' display_functions.sh | grep -c 'sqlite3')"
assert_eq "display.sh makes no sqlite3 calls" "0" \
    "$(grep -v '^[[:space:]]*#' display.sh | grep -c 'sqlite3')"
assert_eq "display_functions.sh queries mariadb" "1" \
    "$(grep -qE '^dq \(\) \{ mysql' display_functions.sh && echo 1 || echo 0)"

# --- the helpers actually run --------------------------------------------
source ./display_functions.sh

assert_eq "rssi_range buckets a near signal"   "near by"      "$(rssi_range -50)"
assert_eq "rssi_range buckets a mid signal"    "medium range" "$(rssi_range -70)"
assert_eq "rssi_range buckets a far signal"    "far away"     "$(rssi_range -90)"
# Multi-antenna RSSI arrives as "-42,-45" and must not break the numeric test.
assert_eq "rssi_range handles multi-antenna rssi" "near by"   "$(rssi_range '-50,-55')"
assert_eq "rssi_range tolerates an empty rssi"    ""          "$(rssi_range '')"

# --- device_banner shows the friendly name and its corroboration ----------
dev=$(sq1 "select distinct device_id from ssid where ssid_hex=lower(hex('RoamHome'));")
alias=$(sq1 "select alias from devices where id = $dev;")
banner=$(device_banner "$dev")

assert_contains "banner names the device by its alias" "$alias" "$banner"
assert_contains "banner reports the merge was confirmed" "confirmed across 3 MACs" "$banner"
assert_contains "banner flags the defeated randomization" "randomization defeated" "$banner"

# A low-confidence device must be called out, not presented as fact.
mysql probeprint -e "update ssid set ie_order='0,1,45', extcap='0xff' where device_id = $dev limit 1;"
source ./seqgraph_functions.sh; seqgraph_refresh_stats
assert_contains "banner warns when a merge is unreliable" \
    "low confidence" "$(device_banner "$dev")"

# --- the device roster ----------------------------------------------------
roster=$(display_devices)
assert_contains "roster lists the device alias" "$alias" "$roster"
assert_contains "roster has a confidence column" "confidence" "$roster"
# Suspect merges sort first so they cannot be missed.
assert_contains "a low-confidence device sorts to the top" "low" \
    "$(echo "$roster" | sed -n '2p')"

# --- per-device PNL, rarest first ----------------------------------------
detail=$(display_device "$alias")
assert_contains "device detail resolves an alias to its device" "$alias" "$detail"
for net in RoamHome RoamCafe RoamWork; do
    assert_contains "detail lists $net in the preferred network list" "$net" "$detail"
done
assert_contains "detail explains why rarity ordering matters" "identifying" "$detail"

# --- recent activity view -------------------------------------------------
# Fixture timestamps are historical, so a window wide enough to include them.
recent=$(display_recent 99999999999)
assert_contains "recent view shows a decoded SSID" "RoamHome" "$recent"
assert_contains "recent view attributes it to a device" "Device:" "$recent"
assert_not_contains "recent view hides the <MISSING> sentinel" "<MISSING>" "$recent"
assert_not_contains "recent view suppresses OTHER_UNKNOWN noise" "OTHER_UNKNOWN" "$recent"

finish
