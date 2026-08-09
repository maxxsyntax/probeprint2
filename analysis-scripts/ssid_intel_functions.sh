#!/bin/bash
# Aggregator. Sources every enrichment concern, so a caller wanting all of them
# needs one line.
#
# This file used to BE the passes -- a dozen unrelated ones in ~350 lines, from
# keyword categorization to airport codes to personal names. idea.txt asks for
# them split per concern, and they now are. What is left here is the union, kept
# so `ssid_intel.sh` and anything else wanting the whole set is unaffected.
#
# A wrapper for a single pass should source that pass's own file instead, so it
# pulls in one concern rather than all of them:
#
#     source ./analysis-scripts/name_functions.sh       # check_name only
#     source ./analysis-scripts/ssid_intel_functions.sh # everything
#
# Order matters in one place: categorize_functions.sh declares the `categories`
# table before sourcing .env, which is what lets an engagement add its own
# INDUSTRY_* keyword lists from there.
source ./analysis-scripts/categorize_functions.sh
source ./analysis-scripts/ssid_intel_rows_functions.sh
source ./analysis-scripts/common_functions.sh
source ./analysis-scripts/name_functions.sh
source ./analysis-scripts/airport_functions.sh
source ./analysis-scripts/fqdn_functions.sh
source ./analysis-scripts/address_functions.sh
source ./analysis-scripts/language_functions.sh

# Shared libraries the passes above call into.
source ./analysis-scripts/vendor_functions.sh
source ./analysis-scripts/rarity_functions.sh
source ./analysis-scripts/industry_functions.sh
source ./analysis-scripts/geolocate_functions.sh
source ./analysis-scripts/location_functions.sh
