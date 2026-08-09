#!/bin/bash
# Capture: get 802.11 probe requests into the database.
#
# The first of the three modules in idea.txt, and the sibling of analysis.sh and
# display.sh. Frames arrive one of two ways -- live off a monitor-mode
# interface, or backfilled from saved captures -- and both land in the same
# `ssid` table through the same parse loop in capture-scripts/ingest_functions.sh.
#
# Usage:
#   ./capture.sh                       live capture from $INF until interrupted
#   ./capture.sh --pcap FILE [FILE...] backfill from saved captures
#   ./capture.sh --pcap-dir DIR        backfill every *.cap/*.pcap under DIR
#   ./capture.sh --status              what has arrived, and is anything arriving
#   ./capture.sh --check               verify the rig can capture, change nothing
#
# Nothing here enriches. Run ./analysis.sh afterwards, or alongside -- the passes
# are incremental and safe to run against a database being written to.

# .env is sourced with plain assignments, so it overwrites anything already in
# the environment. That makes `INF=wlan2mon ./capture.sh` silently capture from
# whatever .env says instead -- the opposite of what anyone typing that expects,
# and invisible until the wrong radio quietly produces no frames.
#
# `${INF+set}` rather than `-n`, so `INF= ./capture.sh --check` counts as an
# override too: that is how you ask preflight to run against no interface.
if [ "${INF+set}" = "set" ]; then _inf_override=$INF; _inf_from_env=1; else _inf_from_env=0; fi
[ -f .env ] && source .env
[ "$_inf_from_env" = "1" ] && INF=$_inf_override

PP_LOG_DIR=${PP_LOG_DIR:-logs}
mkdir -p "$PP_LOG_DIR" 2>/dev/null
chmod 700 "$PP_LOG_DIR" 2>/dev/null

die () { echo "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
#
# Capture fails in a small number of well-known ways, and every one is cheaper
# to report here than to diagnose from an empty table an hour later. Returns 1
# if anything that would stop frames arriving is wrong.
capture_check () {
	local fail=0 warn=0

	printf '%-34s' "tshark installed"
	if command -v tshark >/dev/null 2>&1; then echo "yes"
	else echo "NO -- sudo apt-get install -y tshark"; fail=1; fi

	printf '%-34s' "database reachable"
	if mysql -N probeprint -e "select 1;" >/dev/null 2>&1; then echo "yes"
	else echo "NO -- run ./build_dbs.sh, and check .env"; fail=1; fi

	# INF may list several interfaces, each optionally iface:channel, so each is
	# checked on its own line. A managed-mode interface hears only frames
	# addressed to it, and a probe request is addressed to nobody -- the single
	# most common reason a capture looks alive and collects nothing.
	if [ -z "${INF:-}" ]; then
		printf '%-34s%s\n' "capture interface (\$INF)" "NOT SET -- put INF=wlan1mon in .env"; fail=1
	else
		local token iface mode
		for token in $INF; do
			iface=${token%%:*}
			printf '%-34s' "interface $iface"
			if ! ip link show "$iface" >/dev/null 2>&1; then
				echo "does not exist"; fail=1; continue
			fi
			mode=$(iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')
			case "$mode" in
				monitor) echo "monitor mode${token#$iface}" ;;
				"")      echo "mode unknown (iw not available?)"; warn=1 ;;
				*)       echo "in '$mode' mode, not monitor"; fail=1 ;;
			esac
		done
	fi

	printf '%-34s' "5 GHz coverage"
	local pct
	pct=$(mysql -N probeprint -e \
	  "select round(100.0*sum(freq between 4900 and 7125)/nullif(count(*),0),1) from ssid;" 2>/dev/null)
	if [ -z "$pct" ] || [ "$pct" = "NULL" ]; then echo "no frames yet"
	elif awk -v p="$pct" 'BEGIN{exit !(p < 5)}'; then
		echo "$pct% -- devices probing only on 5 GHz are invisible"; warn=1
	else echo "$pct%"; fi

	[ "$warn" -eq 1 ] && echo "  (warnings do not stop capture; see ./analysis-scripts/fidelity.sh --channels)"
	return $fail
}

# --- status ----------------------------------------------------------------
capture_status () {
	# -N: the rows below are already labelled by their concat(), so the column
	# header is noise that reads as a data row.
	mysql -N probeprint <<'SQL' | sed 's/^/  /'
select concat('frames total            : ', format(count(*),0)) from ssid
union all select concat('  in the last 60s       : ', format(count(*),0))
  from ssid where cast(time as decimal(20,7)) > unix_timestamp() - 60
union all select concat('  in the last hour      : ', format(count(*),0))
  from ssid where cast(time as decimal(20,7)) > unix_timestamp() - 3600
union all select concat('newest frame            : ',
       ifnull(from_unixtime(max(cast(time as decimal(20,7)))), 'none')) from ssid
union all select concat('distinct source MACs    : ', format(count(distinct wlan_sa),0)) from ssid
union all select concat('awaiting device grouping: ', format(count(*),0))
  from ssid where device_id is null;
SQL
	# "Is capture running" is not answerable from the table alone -- an idle
	# channel and a dead radio look identical there.
	local recent
	recent=$(mysql -N probeprint -e \
	  "select count(*) from ssid where cast(time as decimal(20,7)) > unix_timestamp() - 60;" 2>/dev/null)
	echo
	if [ "${recent:-0}" -gt 0 ]; then
		echo "  Frames are arriving."
	elif pgrep -f 'tshark -Qi' >/dev/null 2>&1; then
		echo "  A tshark capture is running but nothing has arrived in 60s."
		echo "  Quiet channel, or the interface is not seeing probe requests."
	else
		echo "  No capture process found and nothing recent. Start one with ./capture.sh"
	fi
}

# --- live ------------------------------------------------------------------
capture_live () {
	capture_check || die "
Preflight failed. Fix the items marked above, or run ./capture.sh --check again."
	echo
	echo "Capturing from $INF. Ctrl-C to stop."
	echo "Frames land in the ssid table; run ./analysis.sh to enrich them."
	echo
	exec ./capture-scripts/build_ssid.sh
}

# --- backfill --------------------------------------------------------------
capture_pcap () {
	[ $# -gt 0 ] || die "usage: $0 --pcap <capture.pcap> [more.pcap ...]"
	command -v tshark >/dev/null 2>&1 || die "tshark is not installed, so no capture can be read."
	exec ./capture-scripts/pcap2db.sh "$@"
}

capture_pcap_dir () {
	local dir=${1:-}
	[ -d "$dir" ] || die "not a directory: $dir"
	local n
	n=$(find "$dir" -maxdepth 1 \( -name '*.cap' -o -name '*.pcap' -o -name '*.pcapng' \) | wc -l)
	[ "$n" -gt 0 ] || die "no captures found in $dir"
	echo "Importing $n capture(s) from $dir"
	# -print0/-0: a capture filename may contain spaces.
	find "$dir" -maxdepth 1 \( -name '*.cap' -o -name '*.pcap' -o -name '*.pcapng' \) -print0 \
	  | xargs -0 ./capture-scripts/pcap2db.sh
}

case "${1:-}" in
	"")          capture_live ;;
	--check)     capture_check ;;
	--status)    capture_status ;;
	--pcap)      shift; capture_pcap "$@" ;;
	--pcap-dir)  shift; capture_pcap_dir "$@" ;;
	# Print the header comment and stop at the first line of code, so the help
	# text cannot drift from the file and cannot run past it either.
	-h|--help)   awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0" ;;
	*)           die "usage: $0 [--pcap FILE...|--pcap-dir DIR|--status|--check]" ;;
esac
