#!/bin/bash
# Daily WiGLE grind: locate every SSID that still lacks a location, waiting out
# the API's daily quota rather than stopping at it.
#
# This is the "wait" quota policy (location_functions.sh::wigle_fetch): when the
# quota is gone it purges the poisoned cache, sleeps $WIGLE_WAIT, and retries, so
# a cron run makes progress across successive quota windows. It can block for a
# long time by design -- run it detached.
#
# It used to `source ./analysis-scripts/online_wigle_fetch.sh`, but that file's `[ $# -eq 0 ]`
# usage guard then saw *this* script's (empty) arguments and exited before any
# work happened, and it called an ssid2loc() summarize_location.sh never defined.
# Both bugs disappear by invoking summarize_location.sh as a subprocess instead.
cd "$(dirname "$0")" || exit 1
exec ./analysis-scripts/online_wigle_fetch.sh --new --wait
