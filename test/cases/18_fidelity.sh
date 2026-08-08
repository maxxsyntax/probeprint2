#!/bin/bash
# Trace fidelity: estimating capture completeness from 802.11 sequence numbers.
#
# Every case builds a synthetic device whose true frame count is known, so the
# estimator can be checked against an answer rather than against itself.
#
# Read-only and offline: the pass only re-reads columns ingest already stored.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "delete from ssid;"

# frames <mac> <base_epoch> <seq...>  -- one probe per sequence number, 0.1s apart
#
# The timestamp is built with bash arithmetic rather than awk: `time` is a
# varchar primary key, so each row needs a distinct fractional value, and
# nesting a quoted awk program inside the SQL string only invites escaping bugs.
frames () {
    local mac=$1 base=$2; shift 2
    local i=0 s ts
    for s in "$@"; do
        ts=$(printf '%d.%06d' $(( base + i / 10 )) $(( (i % 10) * 100000 )))
        mysql probeprint -e "insert ignore into ssid
            (ssid_hex, wlan_sa, time, rssi, freq, seq, is_processed)
          values (lower(hex('fid')), '$mac', '$ts', '-50', 2437, $s, 0);"
        i=$((i+1))
    done
}

source ./analysis-scripts/fidelity_functions.sh

# --- a perfect capture reads 100% -----------------------------------------
frames 'aa:00:00:00:00:01' 1700000000 10 11 12 13 14 15 16 17 18 19
out=$(fidelity_completeness)
assert_contains "an unbroken sequence is 100% complete" "COMPLETENESS (lower bound): 100.0%" "$out"
assert_contains "and every pair is counted as consecutive" "consecutive (no gap)    : 9" "$out"

# --- a known hole is measured, not guessed --------------------------------
# 10 captured frames spanning sequence 0..18, every other one missing. That is
# 9 observed transitions and 9 unaccounted-for frames, so 50%.
#
# The ratio is over frames AFTER THE FIRST in each run: the first frame of a run
# has no predecessor to be measured against. Counting whole frames instead would
# give 10/19 = 52.6%. The difference is one frame per run and vanishes on real
# captures; the pair form is used because it needs no per-device grouping.
mysql probeprint -e "delete from ssid;"
frames 'aa:00:00:00:00:02' 1700000000 0 2 4 6 8 10 12 14 16 18
out=$(fidelity_completeness)
assert_contains "every-other-frame loss is measured exactly" \
    "COMPLETENESS (lower bound): 50.0%" "$out"
assert_contains "and the missing frames are counted" "frames unaccounted for  : 9" "$out"

# --- the 12-bit counter wraps ---------------------------------------------
# 4094, 4095, 0, 1 is three consecutive increments, not a 4000-frame hole.
# Without mod-4096 arithmetic this reads as a catastrophic loss.
mysql probeprint -e "delete from ssid;"
frames 'aa:00:00:00:00:03' 1700000000 4094 4095 0 1
out=$(fidelity_completeness)
assert_contains "a counter wrap is not mistaken for loss" \
    "COMPLETENESS (lower bound): 100.0%" "$out"

# --- retransmissions are not new frames -----------------------------------
# 802.11 reuses the sequence number when it retries. Counting a repeat as a
# fresh frame would report better-than-perfect completeness.
mysql probeprint -e "delete from ssid;"
frames 'aa:00:00:00:00:04' 1700000000 5 5 6 7
out=$(fidelity_completeness)
assert_contains "a retransmission is reported separately" "retransmissions (d = 0)   : 1" "$out"
assert_contains "and does not inflate completeness above 100%" \
    "COMPLETENESS (lower bound): 100.0%" "$out"

# --- an idle gap is not capture loss --------------------------------------
# Two bursts an hour apart. The counter advanced by hundreds in between, but
# the device was elsewhere, not missed -- attributing that to the monitor would
# swamp the estimate.
mysql probeprint -e "delete from ssid;"
frames 'aa:00:00:00:00:05' 1700000000 100 101 102
frames 'aa:00:00:00:00:05' 1700003600 900 901 902
out=$(fidelity_completeness)
assert_contains "frames separated by an idle period are not paired" \
    "COMPLETENESS (lower bound): 100.0%" "$out"
# Dropped for spanning an idle period, which is a different exclusion from a
# delta too large to attribute to loss. Reporting them under one heading would
# hide which assumption is doing the work.
assert_contains "and the pair spanning the idle period is reported" \
    "excluded, outside a burst : 1" "$out"
assert_contains "not conflated with the sequence-delta exclusion" \
    "excluded, delta too large : 0" "$out"

# --- devices are kept apart -----------------------------------------------
# Sequence numbers are per transmitter. Comparing across addresses would invent
# gaps out of two devices' unrelated counters.
mysql probeprint -e "delete from ssid;"
frames 'aa:00:00:00:00:06' 1700000000 1 2 3
frames 'aa:00:00:00:00:07' 1700000000 500 501 502
out=$(fidelity_completeness)
assert_contains "counters are compared within one address only" \
    "COMPLETENESS (lower bound): 100.0%" "$out"

# --- no usable data says so, rather than dividing by zero -----------------
mysql probeprint -e "delete from ssid;"
out=$(fidelity_completeness)
assert_contains "an empty table is stated, not divided by zero" "n/a" "$out"

# --- channel coverage ------------------------------------------------------
mysql probeprint -e "delete from ssid;"
frames 'aa:00:00:00:00:08' 1700000000 1 2 3
out=$(fidelity_channels)
assert_contains "channels are reported with their band" "2.4 GHz" "$out"
assert_contains "a 2.4-only capture is flagged as missing 5 GHz" \
    "Effectively no 5/6 GHz coverage" "$out"

mysql probeprint -e "update ssid set freq = 5200;"
out=$(fidelity_channels)
assert_contains "a 5 GHz capture is identified as such" "5 GHz" "$out"
assert_not_contains "and is not flagged as missing the band" \
    "Effectively no 5/6 GHz coverage" "$out"

# --- strictly read-only ----------------------------------------------------
# Safe to run during capture is the whole point; a pass that wrote would
# contend with ingest.
before=$(sq "select ssid_hex,wlan_sa,time,seq,device_id,is_processed from ssid order by time;" | md5sum)
fidelity_report >/dev/null 2>&1
assert_eq "the pass writes nothing" "$before" \
    "$(sq "select ssid_hex,wlan_sa,time,seq,device_id,is_processed from ssid order by time;" | md5sum)"

# --- offline ---------------------------------------------------------------
out=$(fidelity_report 2>&1)
assert_not_contains "no network host is named" "http" "$out"
assert_contains "the lower-bound caveat is printed with the number" \
    "LOWER BOUND" "$out"

finish
