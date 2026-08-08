#!/bin/bash
# How much of what was transmitted did we actually capture?
#
# Read-only and entirely offline: it re-reads sequence numbers already stored in
# the ssid table and makes no network call, so it is safe to run during capture.
#
# The number it reports is a LOWER BOUND on completeness -- see
# fidelity_functions.sh for why, and read that before quoting the figure at
# anyone. Its main use is calibration, not judging the radio: the sequence graph
# tolerates a gap between frames when deciding two addresses are one device, and
# this measures the gap distribution those tolerances should be fitted to.
#
# Usage:
#   ./analysis-scripts/fidelity.sh              whole collection
#   ./analysis-scripts/fidelity.sh --since 300  last 5 minutes only
#   ./analysis-scripts/fidelity.sh --load       completeness against channel load
#   ./analysis-scripts/fidelity.sh --channels   which channels were listened to
#
# Method: Schulman, Levin & Spring, "On the Fidelity of 802.11 Packet Traces",
# PAM 2008 -- http://www.cs.umd.edu/projects/wifidelity/
[ -f .env ] && source .env
source ./analysis-scripts/fidelity_functions.sh

case "${1:-}" in
	--load)     shift; fidelity_by_load "$@" ;;
	--channels) fidelity_channels ;;
	--since)    fidelity_report --since "${2:-300}" ;;
	"")         fidelity_report ;;
	*)          echo "usage: $0 [--since SECONDS|--load|--channels]" >&2; exit 1 ;;
esac
