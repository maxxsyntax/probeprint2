#!/bin/bash
# Enrichment passes: each must classify its fixture row, and none may treat the
# SQL column header as data.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"

# --- header must never be processed as a row -----------------------------
# Every read loop needs `mysql -N`. Without it the header line "ssid_hex" comes
# back as the first result and gets treated as an SSID.
./standalone_categorize.sh >/tmp/categorize.log 2>&1
assert_eq "no ssid_intel row keyed on the literal 'ssid_hex'" \
    "0" "$(sq1 "select count(*) from ssid_intel where ssid_hex='ssid_hex';")"

# --- categorize ----------------------------------------------------------
assert_eq "Starbucks WiFi -> BIZ_EATERY" "BIZ_EATERY" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Starbucks WiFi'));")"
assert_eq "Hilton Garden Inn -> BIZ_HOTEL" "BIZ_HOTEL" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Hilton Garden Inn'));")"
assert_eq "AndroidAP1234 -> TECH_PHONE" "TECH_PHONE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('AndroidAP1234'));")"
assert_eq "Tesla Model 3 -> CULTURE_CAR" "CULTURE_CAR" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Tesla Model 3'));")"

# Anomalous hex must be flagged, not left unknown.
assert_eq "all-zero ssid_hex -> OTHER_ANOMALOUS" "OTHER_ANOMALOUS" \
    "$(sq1 "select category from ssid_intel where ssid_hex='000000000000';")"

# --- check_language ------------------------------------------------------
assert_eq "Cyrillic SSID -> CULTURE_CRYLIC" "CULTURE_CRYLIC" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex(_utf8mb4'Привет'));")"

# --- check_fqdn ----------------------------------------------------------
# The regression test for the stale-\$ssid bug: this pass could never match
# anything, because \$ssid was decoded before the read loop began.
./standalone_check_fqdn.sh >/tmp/fqdn.log 2>&1
assert_eq "guest.abb -> OTHER_FQDN" "OTHER_FQDN" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('guest.abb'));")"
# An SSID with no dot must not be swept up.
assert_not_contains "SSID without a dot is not marked FQDN" "OTHER_FQDN" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('AndroidAP1234'));")"

# --- check_airport -------------------------------------------------------
./standalone_airport.sh >/tmp/airport.log 2>&1
assert_contains "AMS Airport Free matched the AMS IATA code" "Amsterdam" \
    "$(sq1 "select is_airport from ssid_intel where ssid_hex=lower(hex('AMS Airport Free'));")"

# --- check_name ----------------------------------------------------------
./standalone_name.sh >/tmp/name.log 2>&1
assert_contains "Adam's iPhone yields a name" "Adam" \
    "$(sq1 "select is_name from ssid_intel where ssid_hex=lower(hex('Adam''s iPhone'));")"

# --- check_common --------------------------------------------------------
./standalone_check_common.sh >/tmp/common.log 2>&1
assert_eq "xfinitywifi flagged as common" "1" \
    "$(sq1 "select is_common from ssid_intel where ssid_hex=lower(hex('xfinitywifi'));")"
# NB "Adam's iPhone" is genuinely in lists/ssid.csv (1484 sightings), so it is
# correctly common. Use a made-up SSID for the negative case.
assert_eq "SingleMacNet not flagged as common" "0" \
    "$(sq1 "select is_common from ssid_intel where ssid_hex=lower(hex('SingleMacNet'));")"

# --- mac2vendor ----------------------------------------------------------
# Regression test for two bugs at once: the leaked global IFS='|' meant the
# tab-separated row never split, so ssid_hex was empty and every UPDATE matched
# nothing; and the standalone copy called an undefined mysql_escape.
./standalone_mac2vendor.sh >/tmp/vendor.log 2>&1
assert_contains "OUI 00:1a:11 resolves to Google" "Google" \
    "$(sq1 "select vendor from ssid where wlan_sa='00:1a:11:00:00:01';")"

# --- make_ignore_list ----------------------------------------------------
./standalone_make_ignore.sh >/tmp/ignore.log 2>&1
assert_not_contains "ignore.txt has no 'ssid_hex' header line" \
    "ssid_hex" "$(cat lists/ignore.txt)"

finish
