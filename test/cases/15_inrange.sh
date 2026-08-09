#!/bin/bash
# The in-range operator display: one profile per device, assembled from its PNL.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
./analysis-scripts/categorize.sh    >/dev/null 2>&1
./analysis-scripts/name.sh          >/dev/null 2>&1
./analysis-scripts/airport.sh       >/dev/null 2>&1
./analysis-scripts/rarity.sh        >/dev/null 2>&1
./analysis-scripts/recategorize.sh  >/dev/null 2>&1
./analysis-scripts/language.sh      >/dev/null 2>&1
./analysis-scripts/summarize_loc.sh >/dev/null 2>&1
./analysis-scripts/geolocate.sh     >/dev/null 2>&1
./analysis-scripts/seqgraph.sh      >/dev/null 2>&1

source ./display-scripts/display_functions.sh

# Fixture timestamps are historical, so the window has to reach back to them.
out=$(display_inrange 99999999999)

dev=$(sq1 "select distinct device_id from ssid where wlan_sa='be:00:00:00:04:01';")
alias=$(sq1 "select alias from devices where id = $dev;")

# --- dossier form: device header, subject section below -------------------
# The block is headed by the DEVICE fingerprint -- always present -- with the
# perceived human identity following as a SUBJECT line, because a name is the
# exception, not the rule. This fixture device probes a personal-name network,
# so it has both.
assert_contains "the block is headed by the device fingerprint" "=== $alias" "$out"
assert_contains "and states an approximate proximity" "near by" "$out"
# The human identity appears below, on a SUBJECT line.
assert_contains "the human identity is shown as a SUBJECT" "SUBJECT     :" "$out"

# --- IDENTITY: attributes assembled from the preferred network list -------
assert_contains "household is surfaced" "Household" "$out"
assert_contains "employer is surfaced" "Employer" "$out"
assert_contains "the employer SSID is named" "Vertex Labs Staff" "$out"
assert_contains "language is surfaced" "Language" "$out"
assert_contains "home region is surfaced" "Home region" "$out"
assert_contains "the ISP is named with its country" "Bouygues Telecom (FR)" "$out"
# Locations are merged under one heading rather than four label variants.
assert_contains "everywhere they go is under one heading" "Frequents" "$out"
assert_contains "and includes the airport" "Amsterdam" "$out"
assert_contains "an identifiability score is shown" "identifiability" "$out"

# --- one block per device, not one line per SSID -------------------------
# The whole point of the rework: eight probed networks are one person, one
# dossier. Count this device's own header line.
assert_eq "the device appears exactly once" "1" \
    "$(printf '%s\n' "$out" | grep -c "^=== $alias")"

# --- humans sort ahead of anonymous devices -------------------------------
# The roster still leads with people even though the device heads each block:
# a block carrying a SUBJECT line must appear before the first block without
# one. Parse block by block, keyed on the === header.
assert_eq "an identified subject precedes any unidentified one" "1" \
    "$(printf '%s\n' "$out" | awk '
        /^=== / { blk++; had[blk]=0 }
        /^  SUBJECT     :/ { had[blk]=1 }
        END {
            for (i=1;i<=blk;i++) { if (had[i] && !idf) idf=i; if (!had[i] && !anon) anon=i }
            print (idf>0 && (anon==0 || idf<anon)) ? 1 : 0
        }')"

# --- an unreliable merge is called out before the profile ----------------
mysql probeprint -e "update ssid set ie_order='0,1,45', extcap='0xff'
                      where device_id = $dev limit 1;"
source ./analysis-scripts/seqgraph_functions.sh; seqgraph_refresh_stats
warned=$(display_inrange 99999999999)
assert_contains "a low-confidence fingerprint is flagged as mixed" \
    "UNRELIABLE" "$warned"
# The warning must precede the identity lines, or an operator reads the profile
# first and only learns it is unreliable afterwards.
assert_eq "the warning comes before the identity lines" "1" \
    "$(printf '%s\n' "$warned" | awk '
        /^=== / {seen=1}
        seen && /UNRELIABLE/ {w=NR}
        seen && /Employer/ {e=NR}
        END {print (w>0 && e>0 && w<e) ? 1 : 0}')"

# --- an empty screen distinguishes its three causes -----------------------
# This view is keyed on devices, so a frame with a null device_id cannot appear
# in it however strong the signal. seqgraph is a batch pass, so during live
# capture that is the normal state of the newest frames -- and calling it
# "nothing in range" tells an operator the opposite of the truth: a room full of
# people reads as an empty one.
assert_contains "a silent window reports zero signals" \
    "Zero Signals Observed" "$(display_inrange 1)"
# The window length is not leaked -- "the last 1s" reads as a bug to someone
# who has been watching for minutes.
assert_not_contains "without naming the window length" \
    "last 1s" "$(display_inrange 1)"

# --- ungrouped traffic is still shown -------------------------------------
# During an engagement the enrichment passes may never run: not enough CPU,
# frames arriving too fast. That is a normal operating state, so the display has
# to stay useful in it. Ungrouped frames appear as raw observations keyed on the
# transmitting address, which needs no enrichment at all.
now=$(date +%s)
# Distinct timestamps: `time` is the primary key, so two rows sharing one
# collide and the whole multi-row insert is rejected.
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,device_id) values
  (lower(hex('Tortillas Alizze')),'be:00:00:00:09:01','$now.010000','-44',2437,7100,'0x1',NULL),
  ('<MISSING>','be:00:00:00:09:02','$now.020000','-80',2437,7200,'0x1',NULL);"
out=$(display_inrange 600)

assert_contains "an ungrouped frame still shows its SSID" "Tortillas Alizze" "$out"
assert_contains "and the address that sent it" "be:00:00:00:09:01" "$out"
assert_contains "and a proximity band, not a raw dBm" "near by" "$out"
assert_contains "a wildcard-only device is labeled, not left blank" \
    "(broadcast only)" "$out"

# The operator is standing in a room, not at a terminal. Telling them to go run
# a batch pass is worse than useless -- it may not be affordable at all.
assert_not_contains "no instruction to run an enrichment pass" \
    "analysis-scripts/seqgraph.sh" "$out"
assert_not_contains "and no claim that the room is empty" "Zero Signals" "$out"

# Ordering is by signal so the nearest transmitter reads first.
assert_eq "strongest signal is listed first" "1" \
    "$(printf '%s\n' "$out" | awk '/be:00:00:00:09:01/{a=NR} /be:00:00:00:09:02/{b=NR} END{print (a>0 && b>0 && a<b) ? 1 : 0}')"

# Once grouped, the same frame is a device and leaves the raw list.
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
out=$(display_inrange 600)
assert_not_contains "after seqgraph it is no longer listed as ungrouped" \
    "be:00:00:00:09:01  [" "$out"
assert_eq "and the frame now belongs to a device" "1" \
    "$(sq1 "select count(*) from ssid where ssid_hex=lower(hex('Tortillas Alizze')) and device_id is not null;")"

# --- separator safety -----------------------------------------------------
# SSIDs are arbitrary bytes and routinely contain '|', ',' and tabs, so the row
# separator is char(31). A pipe in an SSID must reach the display whole, not
# split a field. Categorize it OTHER_HOUSEHOLD so it surfaces on a line where
# the whole string is visible.
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('pipe|in|name')),'be:00:00:00:04:02','1700050100.000000','-50',2437,4100,'0x1');"
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('pipe|in|name')));"
mysql probeprint -e "update ssid_intel set category='OTHER_HOUSEHOLD' where ssid_hex=lower(hex('pipe|in|name'));"
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
assert_contains "an SSID containing pipes reaches the display intact" \
    "pipe|in|name" "$(display_inrange 99999999999)"

finish
