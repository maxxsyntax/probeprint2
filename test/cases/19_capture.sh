#!/bin/bash
# capture.sh -- the capture module's entry point.
#
# The live path is not exercised here: it needs a monitor-mode radio, which the
# container has not got. What is tested is everything an operator hits *around*
# it -- preflight, backfill, status and the error paths -- because those are
# what stand between a rig that is capturing and one that only looks like it is.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db

# --- backfill routes through the same ingest as live capture --------------
PCAP=/tmp/cap_entry.pcap
python3 test/fixtures/make_pcap.py "$PCAP" >/dev/null 2>&1
mysql probeprint -e "delete from ssid;"

./capture.sh --pcap "$PCAP" >/tmp/cap_pcap.log 2>&1
assert_eq "--pcap imports frames" "1" "$(sq1 "select count(*) > 0 from ssid;")"
assert_eq "and tags them with the source file, as pcap2db does" "1" \
    "$(sq1 "select count(*) > 0 from ssid where tag like '%cap_entry%';")"

# --- --pcap-dir takes a whole directory -----------------------------------
mkdir -p /tmp/capdir && cp "$PCAP" /tmp/capdir/one.pcap
mysql probeprint -e "delete from ssid;"
out=$(./capture.sh --pcap-dir /tmp/capdir 2>&1)
assert_contains "--pcap-dir reports how many it found" "capture(s) from" "$out"
assert_eq "and imports them" "1" "$(sq1 "select count(*) > 0 from ssid;")"

# --- status tells 'quiet' apart from 'not running' ------------------------
# An idle channel and a dead radio look identical in the table, which is why
# status looks for a capture process too rather than only counting rows.
out=$(./capture.sh --status 2>&1)
assert_contains "status reports the frame total" "frames total" "$out"
assert_contains "status reports what is awaiting device grouping" \
    "awaiting device grouping" "$out"
assert_contains "status says plainly that nothing is capturing" \
    "No capture process found" "$out"
assert_not_contains "and does not leak the SQL column header" "concat(" "$out"

# --- preflight refuses rather than capturing nothing ----------------------
# A managed-mode interface hears only frames addressed to it, and a probe
# request is addressed to nobody: capture looks alive and collects nothing.
# Catching that here is the difference between a wasted minute and a wasted
# engagement.
#
# These also pin the .env precedence fix: .env assigns INF unconditionally, so
# without it an explicit override is silently discarded and the checks below
# would test the wrong interface.
out=$(INF= ./capture.sh --check 2>&1); rc=$?
assert_eq "an unset INF fails preflight" "1" "$rc"
assert_contains "and names the variable to set" "INF=" "$out"

out=$(INF=definitely_not_a_real_iface ./capture.sh --check 2>&1); rc=$?
assert_eq "a missing interface fails preflight" "1" "$rc"
assert_contains "and says which one" "definitely_not_a_real_iface" "$out"

# INF is a list: several interfaces, each optionally iface:channel. Preflight
# reports each one and fails if any is missing, so a three-radio rig with one
# unplugged does not look healthy.
out=$(INF="definitely_not_a_real_iface also_fake:6" ./capture.sh --check 2>&1); rc=$?
assert_eq "a list with a bad interface fails preflight" "1" "$rc"
assert_contains "the first interface is reported by name" "definitely_not_a_real_iface" "$out"
assert_contains "and so is the second" "also_fake" "$out"

out=$(./capture.sh --check 2>&1)
assert_contains "preflight checks tshark" "tshark installed" "$out"
assert_contains "preflight checks the database" "database reachable" "$out"
assert_contains "preflight reports 5 GHz coverage" "5 GHz coverage" "$out"

# --- preflight and status change nothing ----------------------------------
before=$(sq "select ssid_hex,wlan_sa,time from ssid order by time;" | md5sum)
INF= ./capture.sh --check >/dev/null 2>&1
./capture.sh --status >/dev/null 2>&1
assert_eq "neither --check nor --status writes anything" "$before" \
    "$(sq "select ssid_hex,wlan_sa,time from ssid order by time;" | md5sum)"

# --- error paths ----------------------------------------------------------
out=$(./capture.sh --pcap 2>&1); rc=$?
assert_eq "--pcap with no file is an error" "1" "$rc"
assert_contains "and shows the usage" "usage:" "$out"

./capture.sh --pcap-dir /nonexistent >/dev/null 2>&1
assert_eq "--pcap-dir on a missing directory is an error" "1" "$?"

./capture.sh --bogus >/dev/null 2>&1
assert_eq "an unknown option is an error" "1" "$?"

# --- help is generated from the file, so it cannot drift ------------------
out=$(./capture.sh --help 2>&1)
assert_contains "help lists the backfill option" "pcap" "$out"
assert_contains "help lists the status option" "status" "$out"
assert_not_contains "help stops before the code" "PP_LOG_DIR=" "$out"

rm -rf /tmp/capdir "$PCAP"
finish
