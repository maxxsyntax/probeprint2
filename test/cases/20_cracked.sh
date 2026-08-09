#!/bin/bash
# check_cracked -- flag SSIDs whose WPA password is publicly known.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values
  (lower(hex('linksys'))), (lower(hex('MyPrivateNet_9x'))), (lower(hex('NETGEAR-guest'))),
  (lower(hex('He said \"hi\"')));"

# A small known list: two of the four SSIDs above.
cracked=$(mktemp)
printf '%s\n' "$(hexof linksys)" "$(hexof 'NETGEAR-guest')" > "$cracked"

# Point the pass at the test list rather than the shipped one.
cp lists/cracked.txt /tmp/cracked.bak 2>/dev/null
cp "$cracked" lists/cracked.txt

./analysis-scripts/cracked.sh >/tmp/cracked.log 2>&1

assert_eq "an SSID on the list is flagged" "1" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('linksys'));")"
assert_eq "and one with a separator in the name" "1" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('NETGEAR-guest'));")"
assert_eq "an SSID not on the list is explicitly not cracked" "0" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('MyPrivateNet_9x'));")"
assert_eq "and no candidate is left undecided" "0" \
    "$(sq1 "select count(*) from ssid_intel where is_cracked is null;")"

# --- byte-exact matching --------------------------------------------------
# The match is on the hex, so a differently-cased namesake is a different
# network and must not inherit the flag. "Linksys" != "linksys".
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('Linksys')));"
mysql probeprint -e "update ssid_intel set is_cracked=null where ssid_hex=lower(hex('Linksys'));"
./analysis-scripts/cracked.sh >/dev/null 2>&1
assert_eq "a differently-cased namesake is not flagged" "0" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('Linksys'));")"

# --- idempotent, and --recompute overrules --------------------------------
mysql probeprint -e "update ssid_intel set is_cracked=1 where ssid_hex=lower(hex('MyPrivateNet_9x'));"
./analysis-scripts/cracked.sh >/dev/null 2>&1
assert_eq "the incremental pass leaves a decided row alone" "1" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('MyPrivateNet_9x'));")"
./analysis-scripts/cracked.sh --recompute >/dev/null 2>&1
assert_eq "--recompute corrects it back to not-cracked" "0" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('MyPrivateNet_9x'));")"
assert_eq "and the real matches survive --recompute" "1" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('linksys'));")"

# --- it surfaces in the display, but only when the network is rare ---------
# A cracked network is only an actionable soft target if it is rare: a cracked
# 'linksys' is on thousands of devices and impersonating it targets nobody.
# Two devices, both probing a cracked network -- one common, one rare.
printf '%s\n' "$(hexof linksys)" "$(hexof RareCrackedNet)" > lists/cracked.txt
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('RareCrackedNet')));"
mysql probeprint -e "update ssid_intel set rarity = 2  where ssid_hex=lower(hex('linksys'));"
mysql probeprint -e "update ssid_intel set rarity = 19 where ssid_hex=lower(hex('RareCrackedNet'));"
./analysis-scripts/cracked.sh --recompute >/dev/null 2>&1

mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('linksys')),        'ce:00:00:00:01:01','1700099000.000000','-40',2437,8000,'0x1'),
  (lower(hex('RareCrackedNet')), 'ce:00:00:00:02:01','1700099001.000000','-45',2437,8100,'0x1');"
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
source ./display-scripts/display_functions.sh
out=$(display_inrange 99999999999)

assert_contains "a rare cracked network is named as a soft target" \
    "RareCrackedNet" "$out"
assert_contains "under the soft-target label" "Soft target" "$out"
# The common cracked network is flagged in the DB but must not reach the display.
assert_eq "linksys is flagged cracked in the data" "1" \
    "$(sq1 "select is_cracked from ssid_intel where ssid_hex=lower(hex('linksys'));")"
# ...but must not appear on a Soft target line in the display.
assert_not_contains "but a common cracked network is not shown as a target" \
    "linksys" "$(printf '%s\n' "$out" | grep 'Soft target')"

cp /tmp/cracked.bak lists/cracked.txt 2>/dev/null
rm -f "$cracked" /tmp/cracked.bak
finish
