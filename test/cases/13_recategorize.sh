#!/bin/bash
# Second-pass categorization of OTHER_UNKNOWN, and operator/market enumeration
# for consumer premises equipment.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
./analysis-scripts/categorize.sh    >/dev/null 2>&1

# Everything below starts life as OTHER_UNKNOWN -- if categorize() already
# placed one of these, the test would be proving nothing.
for n in 'Bbox-7A21' 'Brightwood-3F17' 'Jacaranda-5G' 'LEDnet00040486FF' 'La Maison-Invitados'; do
    assert_eq "'$n' starts as OTHER_UNKNOWN" "OTHER_UNKNOWN" \
        "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('$n'));")"
done

./analysis-scripts/recategorize.sh >/tmp/recat.log 2>&1

# --- operator brands from lists/cpe_isp.txt -------------------------------
assert_eq "Bbox is recognized as CPE" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Bbox-7A21'));")"
assert_eq "and attributed to its operator" "Bouygues Telecom" \
    "$(sq1 "select cpe_isp from ssid_intel where ssid_hex=lower(hex('Bbox-7A21'));")"
assert_eq "and to a single national market" "FR|country" \
    "$(sq1 "select concat_ws('|',cpe_country,cpe_scope) from ssid_intel where ssid_hex=lower(hex('Bbox-7A21'));")"

assert_eq "BTHub resolves to the UK" "GB|country" \
    "$(sq1 "select concat_ws('|',cpe_country,cpe_scope) from ssid_intel where ssid_hex=lower(hex('BTHub6-XKQP'));")"
assert_eq "MEO_ resolves to Portugal" "PT|country" \
    "$(sq1 "select concat_ws('|',cpe_country,cpe_scope) from ssid_intel where ssid_hex=lower(hex('MEO_WiFi_2E'));")"

# An operator spanning several markets narrows to a region, not a country.
assert_eq "MOVISTAR is scoped as a region, not a country" "region" \
    "$(sq1 "select cpe_scope from ssid_intel where ssid_hex=lower(hex('MOVISTAR_A4F2'));")"
assert_contains "and lists the markets it covers" "ES" \
    "$(sq1 "select cpe_country from ssid_intel where ssid_hex=lower(hex('MOVISTAR_A4F2'));")"

# --- a hardware vendor must never imply a location ------------------------
# This is the guard that stops a NETGEAR router being read as evidence of origin.
assert_eq "a vendor SSID is CPE" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('NETGEAR58-Guest'));")"
assert_eq "but is scoped as vendor" "vendor" \
    "$(sq1 "select cpe_scope from ssid_intel where ssid_hex=lower(hex('NETGEAR58-Guest'));")"
assert_eq "and claims no country" "none" \
    "$(sq1 "select cpe_country from ssid_intel where ssid_hex=lower(hex('NETGEAR58-Guest'));")"
assert_eq "no vendor row leaks into the country-scoped set" "0" \
    "$(sq1 "select count(*) from ssid_intel where cpe_scope='vendor' and cpe_country not in ('none','');")"

# --- shape alone, with no recognizable brand ------------------------------
assert_eq "a trailing MAC fragment marks CPE" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Brightwood-3F17'));")"
assert_eq "a band suffix marks CPE" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Jacaranda-5G'));")"
# But shape-only matches must claim no operator.
assert_eq "shape-only CPE names no operator" "NULL" \
    "$(sq1 "select ifnull(cpe_isp,'NULL') from ssid_intel where ssid_hex=lower(hex('Brightwood-3F17'));")"

# The precision case: '5G' inside a phone model must not look like a router.
assert_not_contains "a phone model containing 5G is not called CPE" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Galaxy A53 5G 0F92'));")"

# --- narrower classes -----------------------------------------------------
assert_eq "Spanish guest network is recognized" "TECH_GUEST" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('La Maison-Invitados'));")"
assert_eq "a smart-home appliance is recognized" "TECH_IOT" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('LEDnet00040486FF'));")"
assert_eq "an all-digits SSID is classed numeric" "OTHER_NUMERIC" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('4085551234'));")"

# --- restraint: unplaceable names stay unplaced ---------------------------
assert_eq "a genuinely unplaceable name stays OTHER_UNKNOWN" "OTHER_UNKNOWN" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Quebrador San Miguel'));")"

# --- never overwrite a decided category -----------------------------------
assert_eq "an already-categorized SSID is untouched" "BIZ_EATERY" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Starbucks WiFi'));")"
assert_eq "and a phone match is untouched" "TECH_PHONE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Adam''s iPhone'));")"

# --- idempotent -----------------------------------------------------------
before=$(sq "select ssid_hex,category,ifnull(cpe_isp,'') from ssid_intel order by ssid_hex;" | md5sum)
./analysis-scripts/recategorize.sh >/dev/null 2>&1
assert_eq "re-running changes nothing" "$before" \
    "$(sq "select ssid_hex,category,ifnull(cpe_isp,'') from ssid_intel order by ssid_hex;" | md5sum)"

# --- reporting ------------------------------------------------------------
assert_contains "the run reports how many came from a brand" \
    "TECH_CPE from an operator brand" "$(cat /tmp/recat.log)"
assert_contains "and how many from shape alone" \
    "TECH_CPE from name shape only" "$(cat /tmp/recat.log)"
assert_contains "and how many it refused to place" \
    "still OTHER_UNKNOWN" "$(cat /tmp/recat.log)"

rep=$(./analysis-scripts/recategorize.sh --regions 2>&1)
assert_contains "the region report separates single markets" \
    "residential origin, by operator market" "$rep"
assert_contains "and keeps vendors out of that section" \
    "no geography: hardware vendors" "$rep"

# --- patterns mined from the residual OTHER_UNKNOWN set -------------------
assert_eq "a newly added operator resolves to its market" "UA|country" \
    "$(sq1 "select concat_ws('|',cpe_country,cpe_scope) from ssid_intel where ssid_hex=lower(hex('Ukrtelecom_4471'));")"
assert_eq "a workplace marker is recognized" "BIZ_STAFF" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Torres Staff'));")"
assert_eq "a residence marker is recognized" "OTHER_HOUSEHOLD" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Ruiz Family'));")"
assert_eq "a trailing generic network word marks CPE" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Alvarez_network'));")"

# Precision guard. 'red' is the Spanish word for network but also an English
# color, so it is matched only as a trailing token -- 'Redwood Lodge' must not
# be swept into CPE by it.
assert_not_contains "a word merely containing a net token is untouched" "TECH_CPE" \
    "$(sq1 "select category from ssid_intel where ssid_hex=lower(hex('Redwood Lodge'));")"

assert_contains "the run reports workplace markers separately" \
    "BIZ_STAFF (workplace marker)" "$(cat /tmp/recat.log)"
assert_contains "and residence markers separately" \
    "OTHER_HOUSEHOLD (residence)" "$(cat /tmp/recat.log)"

# The counters must reflect work actually done. They previously ran inside a
# `{ ... } | mysql` brace group, which bash executes in a subshell, so every
# increment was discarded and the report printed zeros over a successful run.
assert_eq "the brand counter is not stuck at zero" "1" \
    "$(awk -F: '/-> TECH_CPE from an operator brand/ {print ($2+0 > 0) ? 1 : 0; exit}' /tmp/recat.log)"
assert_eq "the household counter is not stuck at zero" "1" \
    "$(awk -F: '/-> OTHER_HOUSEHOLD/ {print ($2+0 > 0) ? 1 : 0; exit}' /tmp/recat.log)"

finish
