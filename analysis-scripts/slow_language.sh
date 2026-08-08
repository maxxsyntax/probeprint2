#!/bin/bash
# Identify the language of Latin-script SSIDs by vocabulary.
#
# Complements check_language() in ssid_intel_functions.sh, which detects
# languages by SCRIPT and therefore cannot see anything written in Latin
# characters. See language_functions.sh for why the rules are strict.
#
# Usage:
#   ./analysis-scripts/slow_language.sh              classify rows with no language yet
#   ./analysis-scripts/slow_language.sh --recompute  reclassify everything
#   ./analysis-scripts/slow_language.sh --report     what was found, and what script
#                                         detection found for comparison
[ -f .env ] && source .env
source ./analysis-scripts/language_functions.sh

case "${1:-}" in
	--report)    language_report ;;
	--recompute) check_language_words --recompute; language_report ;;
	*)           check_language_words;             language_report ;;
esac
