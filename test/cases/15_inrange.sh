#!/bin/bash
# The in-range operator display: one profile per device, assembled from its PNL.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
./standalone_categorize.sh    >/dev/null 2>&1
./standalone_name.sh          >/dev/null 2>&1
./standalone_airport.sh       >/dev/null 2>&1
./standalone_rarity.sh        >/dev/null 2>&1
./standalone_recategorize.sh  >/dev/null 2>&1
./standalone_language.sh      >/dev/null 2>&1
./standalone_summarize_loc.sh >/dev/null 2>&1
./standalone_geolocate.sh     >/dev/null 2>&1
./standalone_seqgraph.sh      >/dev/null 2>&1

source ./display_functions.sh

# Fixture timestamps are historical, so the window has to reach back to them.
out=$(display_inrange 99999999999)

dev=$(sq1 "select distinct device_id from ssid where wlan_sa='be:00:00:00:04:01';")
alias=$(sq1 "select alias from devices where id = $dev;")

# --- the device is identified by its friendly name, not an id ------------
assert_contains "the profile leads with the friendly name" "$alias" "$out"
assert_contains "and states an approximate proximity" "near by" "$out"

# --- attributes assembled from the preferred network list ----------------
assert_contains "household is surfaced" "Household" "$out"
assert_contains "employer is surfaced" "Employer" "$out"
assert_contains "the employer SSID is named" "Vertex Labs Staff" "$out"
assert_contains "language is surfaced" "Language" "$out"
assert_contains "home ISP and market are surfaced" "Home ISP" "$out"
assert_contains "the ISP is named with its country" "Bouygues Telecom (FR)" "$out"
assert_contains "geolocated places are surfaced" "Places" "$out"
assert_contains "airports are surfaced" "Airports" "$out"
assert_contains "the airport is named" "Amsterdam" "$out"
assert_contains "hotels and travel are surfaced" "Hotels/tvl" "$out"
assert_contains "eateries are surfaced" "Eateries" "$out"
assert_contains "an identifiability score is shown" "identifiability" "$out"

# --- one block per device, not one line per SSID -------------------------
# The whole point of the rework: eight probed networks are one person.
assert_eq "the device appears exactly once" "1" \
    "$(printf '%s\n' "$out" | grep -c "^$alias  \[")"

# --- an unreliable merge is called out before the profile ----------------
mysql probeprint -e "update ssid set ie_order='0,1,45', extcap='0xff'
                      where device_id = $dev limit 1;"
source ./seqgraph_functions.sh; seqgraph_refresh_stats
warned=$(display_inrange 99999999999)
assert_contains "a low-confidence fingerprint is flagged as mixed" \
    "UNRELIABLE" "$warned"
# The warning must precede the attributes, or an operator reads the profile first.
assert_eq "the warning comes before the profile lines" "1" \
    "$(printf '%s\n' "$warned" | awk -v a="$alias" '
        $0 ~ "^" a "  \\[" {seen=1}
        seen && /UNRELIABLE/ {w=NR}
        seen && /Employer/ {e=NR}
        END {print (w>0 && e>0 && w<e) ? 1 : 0}')"

# --- an empty room says so -----------------------------------------------
assert_contains "an empty window is stated, not left blank" \
    "nothing in range" "$(display_inrange 1)"

# --- separator safety -----------------------------------------------------
# SSIDs are arbitrary bytes and routinely contain '|', ',' and tabs, so the row
# separator is char(31). A pipe in an SSID must not split the row.
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('pipe|in|name')),'be:00:00:00:04:02','1700050100.000000','-50',2437,4100,'0x1');"
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('pipe|in|name')));"
./standalone_seqgraph.sh >/dev/null 2>&1
assert_not_contains "an SSID containing pipes does not corrupt the display" \
    "Household   : pipe" "$(display_inrange 99999999999)"

finish
