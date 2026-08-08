#!/bin/bash
# Run every enrichment pass, in dependency order.
#
# All passes are incremental: each skips rows it has already done, so this is
# cheap to re-run after new capture and safe to interrupt and restart.
#
# Usage:
#   ./analysis.sh                 enrich whatever is not yet enriched
#   ./analysis.sh --recompute     re-derive everything, including existing rows
#   ./analysis.sh --list          show the passes and stop
#
# Nothing here touches the network. WiGLE lookups are not part of this script:
# geolocation reads only the cached responses in $GEO_LOCS_DIR. To fetch new
# ones, run `./analysis-scripts/online_wigle_fetch.sh --new` separately and mind the daily quota.
#
# Environment:
#   GEO_LOCS_DIR   where the WiGLE cache lives          (default: locs)
#   PP_LOG_DIR     where per-pass logs are written      (default: logs)
#   DB_USER/DB_HOST  passed to scripts that support it  (default: local socket)
[ -f .env ] && source .env

RECOMPUTE=""
case "${1:-}" in
	--recompute) RECOMPUTE="--recompute" ;;
	--list)      LIST_ONLY=1 ;;
	"")          ;;
	*)           echo "usage: $0 [--recompute|--list]" >&2; exit 1 ;;
esac

export GEO_LOCS_DIR=${GEO_LOCS_DIR:-locs}

# Per-pass logs go inside the workspace, not /tmp.
#
# Two reasons, and the second is the one that matters. /tmp is shared, so a
# fixed name like /tmp/pp_categorize.log belongs to whichever user created it
# first -- run this once under sudo or from a container and every later run as
# yourself dies at the redirect with "Permission denied", before the pass it
# was about to log even starts.
#
# More importantly these logs are capture data. They carry SSIDs, device MACs
# and the locations derived from them, so writing them to a world-readable path
# with a predictable name publishes an engagement's PII to every account on the
# host. Collected data stays in the workspace.
PP_LOG_DIR=${PP_LOG_DIR:-logs}
if ! mkdir -p "$PP_LOG_DIR" 2>/dev/null; then
	echo "Cannot create log directory '$PP_LOG_DIR'." >&2
	echo "Set PP_LOG_DIR to a writable path and re-run." >&2
	exit 1
fi
chmod 700 "$PP_LOG_DIR" 2>/dev/null

# --- ordering ---------------------------------------------------------------
#
# Only three constraints actually matter; the rest is grouping for readability.
#
#   ssid2ssid_intel must run first          -- nothing else has rows to work on
#   rarity must precede seqgraph            -- pnl_rarity sums ssid_intel.rarity
#   geolocate must precede oneloc           -- is_oneloc derives from
#                                              geo_match_count, and refuses
#                                              rather than guessing without it
#
# recategorize only re-examines what categorize left as OTHER_UNKNOWN, so it
# follows categorize. language reads the same rows and is independent of both.

# Where the passes live. Each is runnable on its own from the repo root -- the
# batch runner and the standalone invocation are the same script, which is what
# idea.txt asks for.
PASS_DIR=analysis-scripts

run_pass () {
	local script=$1; shift
	# Strip the online_/slow_ tags for the display label: they describe how a
	# pass behaves, not what it does, and the header below already groups by
	# stage. The tags stay in the filename so `ls` warns you before you run one.
	local label=${script%.sh}
	label=${label#online_}; label=${label#slow_}

	if [ ! -x "./$PASS_DIR/$script" ]; then
		printf '  %-22s SKIP  (not found or not executable)\n' "$label"
		return 0
	fi

	local start rc log
	log="$PP_LOG_DIR/$label.log"
	start=$(date +%s)
	if "./$PASS_DIR/$script" "$@" >"$log" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	local elapsed=$(( $(date +%s) - start ))

	if [ "$rc" -eq 0 ]; then
		printf '  %-22s ok    %4ss\n' "$label" "$elapsed"
	else
		printf '  %-22s FAIL  %4ss  (exit %s, see %s)\n' \
			"$label" "$elapsed" "$rc" "$log"
		FAILED="$FAILED $label"
	fi
	return 0
}

PASSES_CLASSIFY="ssid2ssid_intel.sh
categorize.sh
recategorize.sh
slow_language.sh
name.sh
airport.sh
address.sh
fqdn.sh
industry.sh"

PASSES_ENRICH="mac2vendor.sh
rarity.sh"

PASSES_LOCATE="slow_summarize_loc.sh
geolocate.sh
oneloc.sh"

PASSES_DEVICE="seqgraph.sh"

if [ -n "${LIST_ONLY:-}" ]; then
	echo "classification:"; printf '  %s\n' $PASSES_CLASSIFY
	echo "enrichment:";     printf '  %s\n' $PASSES_ENRICH
	echo "location:";       printf '  %s\n' $PASSES_LOCATE
	echo "devices:";        printf '  %s\n' $PASSES_DEVICE
	exit 0
fi

FAILED=""
TOTAL_START=$(date +%s)

echo "=============================================================="
echo " probeprint2 enrichment $([ -n "$RECOMPUTE" ] && echo '(full recompute)' || echo '(incremental)')"
echo " locs cache: $GEO_LOCS_DIR"
echo "=============================================================="

echo
echo "-- classification ------------------------------------------------"
for p in $PASSES_CLASSIFY; do run_pass "$p"; done

echo
echo "-- vendor and rarity ---------------------------------------------"
run_pass mac2vendor.sh
# rarity takes --recompute; --reload additionally rebuilds ssid_freq from
# lists/ssid.csv, which is only needed when that list is re-downloaded.
run_pass rarity.sh $RECOMPUTE

echo
echo "-- location (offline, from the WiGLE cache) ----------------------"
run_pass slow_summarize_loc.sh
run_pass geolocate.sh $RECOMPUTE
run_pass oneloc.sh $RECOMPUTE

echo
echo "-- devices and preferred network lists ---------------------------"
run_pass seqgraph.sh $RECOMPUTE

echo
echo "=============================================================="
printf ' elapsed: %ss\n' "$(( $(date +%s) - TOTAL_START ))"
if [ -n "$FAILED" ]; then
	printf ' FAILED:%s\n' "$FAILED"
else
	echo " all passes completed"
fi
echo "=============================================================="

echo
echo "-- coverage ------------------------------------------------------"
mysql probeprint <<'SQL' | sed 's/^/  /'
select concat('ssid_intel rows        : ', count(*)) from ssid_intel
union all select concat('  categorized          : ', count(*)) from ssid_intel where category is not null
union all select concat('  still OTHER_UNKNOWN  : ', count(*)) from ssid_intel where category = 'OTHER_UNKNOWN'
union all select concat('  with a name          : ', count(*)) from ssid_intel where is_name is not null and is_name not in ('0','')
union all select concat('  scored for rarity    : ', count(*)) from ssid_intel where rarity is not null
union all select concat('  with coordinates     : ', count(*)) from ssid_intel where lat is not null
union all select concat('    definitive (1 exact match): ', count(*)) from ssid_intel where geo_match_count = 1 and lat is not null
union all select concat('  flagged INDUSTRY_ORG : ', count(*)) from ssid_intel where category = 'INDUSTRY_ORG'
union all select concat('devices                : ', count(*)) from devices
union all select concat('  low confidence       : ', count(*)) from devices where confidence = 'low'
union all select concat('device_ssid (PNL) rows : ', count(*)) from device_ssid;
SQL

[ -n "$FAILED" ] && exit 1
exit 0
