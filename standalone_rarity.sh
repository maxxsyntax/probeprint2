#!/bin/bash
# Score every SSID by how rare it is, which is what makes preferred-network-list
# linkage work. See rarity_functions.sh for the reasoning and the formula.
#
# Usage:
#   ./standalone_rarity.sh              incremental; loads ssid_freq if empty
#   ./standalone_rarity.sh --reload     rebuild ssid_freq from lists/ssid.csv
#   ./standalone_rarity.sh --recompute  rescore every SSID, not just new ones
source ./rarity_functions.sh

case "${1:-}" in
	--reload)    load_ssid_frequencies --reload; score_rarity ;;
	--recompute) load_ssid_frequencies;          score_rarity --recompute ;;
	*)           load_ssid_frequencies;          score_rarity ;;
esac
