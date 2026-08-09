#!/bin/bash
# Flag SSIDs whose WPA password is publicly known, from lists/cracked.txt.
#
# Offline, idempotent, null-driven. See cracked_functions.sh.
#
# Usage:
#   ./analysis-scripts/cracked.sh              flag rows not yet checked
#   ./analysis-scripts/cracked.sh --recompute  re-check every row
[ -f .env ] && source .env
source ./analysis-scripts/cracked_functions.sh

check_cracked "${1:-}"
