#!/bin/bash
# Link probe requests into devices across MAC randomisation, using the 802.11
# sequence counter, and attach each device's preferred network list.
# See seqgraph_functions.sh for the algorithm and its source.
#
# Usage:
#   ./standalone_seqgraph.sh              assign device ids to unassigned frames
#   ./standalone_seqgraph.sh --recompute  rebuild the graph over every frame
#   ./standalone_seqgraph.sh --report     devices, their PNLs and confidence
#   ./standalone_seqgraph.sh --validate   measure accuracy against static MACs
#   ./standalone_seqgraph.sh --pnl        rebuild device_ssid only
#
# Tuning, via .env:
#   SEQGRAPH_ALPHA    max seconds one edge may bridge     (default 90)
#   SEQGRAPH_BETA     max sequence advance per edge       (default 400)
#   SEQGRAPH_GATE_IE  1 = block edges between frames whose IE fingerprints
#                     disagree, which prevents most false merges (default 1)
#
# --validate is the one to run on a real capture before trusting any of this:
# it scores the clustering against the devices that do not randomise their MAC,
# which are ground truth requiring no inference at all.
[ -f .env ] && source .env
source ./seqgraph_functions.sh

case "${1:-}" in
	--report)    seqgraph_report ;;
	--validate)  seqgraph_validate ;;
	--pnl)       seqgraph_refresh_pnl; seqgraph_refresh_stats ;;
	--recompute) seqgraph_assign --recompute; seqgraph_report; echo; seqgraph_validate ;;
	*)           seqgraph_assign;             seqgraph_report; echo; seqgraph_validate ;;
esac
