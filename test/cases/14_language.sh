#!/bin/bash
# Language detection by vocabulary, for the Latin-script SSIDs that
# check_language()'s script matching cannot see at all.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
./analysis-scripts/categorize.sh >/dev/null 2>&1

# The premise: script detection is blind to every one of these.
assert_eq "script detection leaves Latin-script German unclassified" "OTHER_UNKNOWN" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Netzwerk Mueller'));")"

./analysis-scripts/slow_language.sh >/tmp/lang.log 2>&1

# --- single-language markers ----------------------------------------------
assert_eq "German is identified from vocabulary" "de|language" \
    "$(sq1 "select concat_ws('|',lang,lang_scope) from ssid_intel where ssid_hex=lower(hex('Netzwerk Mueller'));")"
assert_eq "Dutch is identified" "nl|language" \
    "$(sq1 "select concat_ws('|',lang,lang_scope) from ssid_intel where ssid_hex=lower(hex('Huis van Dijk'));")"
assert_eq "Spanish is identified" "es|language" \
    "$(sq1 "select concat_ws('|',lang,lang_scope) from ssid_intel where ssid_hex=lower(hex('Cocina Abajo'));")"
assert_eq "French is identified" "fr|language" \
    "$(sq1 "select concat_ws('|',lang,lang_scope) from ssid_intel where ssid_hex=lower(hex('Maison Dupont'));")"

# --- a family-only marker must not name one language ----------------------
# 'casa' is Spanish, Italian, Portuguese and Romanian. Claiming Spanish would
# be inventing a nationality.
assert_eq "a shared Romance word yields the family, not a language" "family" \
    "$(sq1 "select lang_scope from ssid_intel where ssid_hex=lower(hex('Casa Bonita'));")"
assert_contains "and lists every member it could be" "it" \
    "$(sq1 "select lang from ssid_intel where ssid_hex=lower(hex('Casa Bonita'));")"

# --- whole-token matching ---------------------------------------------------
# 'red' is Spanish for network, but 'Redwood' is not Spanish.
assert_eq "a marker inside a longer word does not match" "NULL" \
    "$(sq1 "select ifnull(lang,'NULL') from ssid_intel where ssid_hex=lower(hex('Redwood Cabin'));")"

# --- conflicting evidence is refused, not guessed --------------------------
assert_eq "German and Italian markers together yield no language" "NULL" \
    "$(sq1 "select ifnull(lang,'NULL') from ssid_intel where ssid_hex=lower(hex('Netzwerk Cucina'));")"
assert_contains "and the refusal is counted" "conflicting markers, refused" "$(cat /tmp/lang.log)"

# --- category is filled in only for still-unknown rows --------------------
assert_eq "a confident language clears OTHER_UNKNOWN" "CULTURE_DE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Netzwerk Mueller'));")"
assert_eq "an already-categorized SSID keeps its category" "BIZ_EATERY" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Starbucks WiFi'));")"
# A family match is not confident enough to name a culture.
assert_not_contains "a family-only match does not set CULTURE_" "CULTURE_" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Casa Bonita'));")"

# --- idempotent -----------------------------------------------------------
before=$(sq "select ssid_hex,ifnull(lang,''),ifnull(lang_scope,'') from ssid_intel order by ssid_hex;" | md5sum)
./analysis-scripts/slow_language.sh >/dev/null 2>&1
assert_eq "re-running changes nothing" "$before" \
    "$(sq "select ssid_hex,ifnull(lang,''),ifnull(lang_scope,'') from ssid_intel order by ssid_hex;" | md5sum)"

assert_contains "the report compares against script detection" \
    "what script detection alone found" "$(./analysis-scripts/slow_language.sh --report 2>&1)"

finish
