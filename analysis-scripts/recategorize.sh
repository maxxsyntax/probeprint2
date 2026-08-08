#!/bin/bash
# Try to place SSIDs that categorize() left as OTHER_UNKNOWN, and work out which
# operator's equipment the TECH_CPE ones belong to.
#
# Usage:
#   ./analysis-scripts/recategorize.sh                 recategorize, then enumerate operators
#   ./analysis-scripts/recategorize.sh --include-null  also take rows with no category
#   ./analysis-scripts/recategorize.sh --cpe-only      only enumerate operators
#   ./analysis-scripts/recategorize.sh --report        category counts
#   ./analysis-scripts/recategorize.sh --regions       residential origin by market
#
# Never overwrites a category that was already decided, so it is safe to re-run
# and cannot undo categorize(), check_name(), check_fqdn() or check_language().
# Reads lists/cpe_isp.txt for the operator mapping.
[ -f .env ] && source .env
source ./analysis-scripts/recategorize_functions.sh

case "${1:-}" in
	--cpe-only)
		enumerate_cpe_region
		cpe_region_report
		;;
	--report)
		recategorize_report
		;;
	--regions)
		cpe_region_report
		;;
	--include-null)
		recategorize_unknown --include-null
		enumerate_cpe_region
		recategorize_report
		;;
	*)
		recategorize_unknown
		enumerate_cpe_region
		recategorize_report
		;;
esac
