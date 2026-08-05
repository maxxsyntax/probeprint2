#!/bin/bash
# Link probe requests into devices across MAC randomisation, using the 802.11
# sequence counter. See seqgraph_functions.sh for the algorithm and its source.
#
# Usage:
#   ./standalone_seqgraph.sh              assign device_id to unassigned frames
#   ./standalone_seqgraph.sh --recompute  rebuild the graph over every frame
#   ./standalone_seqgraph.sh --report     show devices and their MAC counts
#
# Tuning, via .env:
#   SEQGRAPH_ALPHA   max seconds one edge may bridge   (default 90)
#   SEQGRAPH_BETA    max sequence advance per edge     (default 400)
[ -f .env ] && source .env
source ./seqgraph_functions.sh

case "${1:-}" in
	--report)    seqgraph_report ;;
	--recompute) seqgraph_assign --recompute; seqgraph_report ;;
	*)           seqgraph_assign;             seqgraph_report ;;
esac
