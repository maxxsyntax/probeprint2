#!/bin/bash
# Mark the SSIDs that name exactly one place on earth.
#
# This used to grep the cached WiGLE body for `"totalResults": 1`. That number
# counts WiGLE's case-INSENSITIVE matches, so "MyNet" and "mynet" -- different
# networks, different owners, different cities -- inflate it together. The flag
# was wrong for most of its positives, in both directions: unique networks read
# as ambiguous whenever a differently-cased namesake existed anywhere, and
# ambiguous names read as unique whenever their namesakes shared a case.
#
# It is now derived from geo_match_count, which counts results matching the
# probed SSID byte-for-byte -- a probe request carries one exact string. See
# derive_is_oneloc in geolocate_functions.sh.
#
# Requires ./analysis-scripts/geolocate.sh to have run first. It refuses rather than
# falling back to the old heuristic, because a silent fallback would reintroduce
# the same error with no way for the caller to tell.
#
# Usage:
#   ./analysis-scripts/oneloc.sh              decide rows not yet decided
#   ./analysis-scripts/oneloc.sh --recompute  re-derive every row
[ -f .env ] && source .env
source ./analysis-scripts/geolocate_functions.sh

derive_is_oneloc "${1:-}"
