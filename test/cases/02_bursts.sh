#!/bin/bash
# Burst grouping: all three methods must actually produce bursts.
#
# Before the fixes, grouping by MAC failed on a SQL syntax error (a missing
# `and`) and grouping by sequence number returned nothing (`seq!=null` is never
# true), so `bursts` stayed empty no matter how much data was collected.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

source ./analysis-scripts/bursts_functions.sh
reset_db

# --- grouping by MAC address ---------------------------------------------
ssid_2bursts-wlan_sa >/tmp/burst_mac.log 2>&1

assert_not_contains "wlan_sa pass produced no SQL error" \
    "ERROR" "$(cat /tmp/burst_mac.log)"

# Keyed on this fixture's own burst rather than a global count: other fixtures
# in seed.sql (the sequence-graph rotations) legitimately form bursts too.
BURST_T=1700000200.100000

assert_eq "wlan_sa pass created a burst for the 4-frame MAC" \
    "1" "$(sq1 "select count(*) from bursts where time='$BURST_T' and bmethod='wlan_sa';")"

assert_eq "burst contains all 4 probes from the shared MAC" \
    "4" "$(sq1 "select burst_size from bursts where time='$BURST_T';")"

# All four member SSIDs must appear in the colon-joined ssids column.
ssids=$(sq1 "select ssids from bursts where time='$BURST_T';")
for name in BurstAlpha BurstBravo BurstCharlie BurstDelta; do
    assert_contains "burst ssids include $name" "$(hexof $name)" "$ssids"
done

assert_eq "burst members marked is_processed=100" \
    "4" "$(sq1 "select count(*) from ssid where wlan_sa='0a:00:00:00:00:01' and is_processed=100;")"

assert_eq "burst duration is non-zero" \
    "1" "$(sq1 "select burst_duration+0 > 0 from bursts where time='$BURST_T';")"

# --- grouping by sequence number -----------------------------------------
ssid2bursts-seq >/tmp/burst_seq.log 2>&1

assert_not_contains "seq pass produced no SQL error" \
    "ERROR" "$(cat /tmp/burst_seq.log)"

# The three SeqBurst* rows share an RSSI band and fall inside the +60 sequence
# window, so they group despite having randomized (distinct) MAC addresses.
assert_eq "seq pass created at least one burst" \
    "1" "$(sq1 "select least(count(*),1) from bursts where bmethod='seq';")"

# --- grouping by VHT tag -------------------------------------------------
ssid2bursts-vht >/tmp/burst_vht.log 2>&1

assert_not_contains "vht pass produced no SQL error" \
    "ERROR" "$(cat /tmp/burst_vht.log)"

assert_eq "vht pass created at least one burst" \
    "1" "$(sq1 "select least(count(*),1) from bursts where bmethod='vht';")"

# --- RSSI no longer gates burst membership -------------------------------
# Both passes used to require two frames to be within +/-2 dBm. Measured on a
# labelled corpus of 22 stationary devices in a semi-anechoic chamber -- the
# quietest such capture can be -- consecutive frames from ONE device moved a
# mean of 9.6 dBm and exceeded 2 dBm 40% of the time, so the gate was rejecting
# about 40% of genuine same-device pairs.
#
# Two frames 55 dBm apart, adjacent in time and sequence, must now group.
mysql probeprint -e "delete from bursts where bmethod='seq';"
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,is_processed) values
  (lower(hex('WideSwingA')),'0a:00:00:00:0e:01','1700060000.000000','-20',2437,900,'0x1',1),
  (lower(hex('WideSwingB')),'0a:00:00:00:0e:02','1700060000.400000','-75',2437,902,'0x1',1);"
ssid2bursts-seq >/tmp/burst_rssi.log 2>&1

assert_eq "frames 55 dBm apart still form one burst" "1" \
    "$(sq1 "select count(*) from bursts
             where bmethod='seq' and time='1700060000.000000' and burst_size >= 2;")"
assert_not_contains "and the pass reported no error doing it" \
    "ERROR" "$(cat /tmp/burst_rssi.log)"

# A frame with no radiotap has no RSSI at all. It used to be pushed out of this
# stage unmatchable; sequence number is what this method correlates on, and that
# is still present.
mysql probeprint -e "delete from bursts where bmethod='seq';"
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,is_processed) values
  (lower(hex('NoRadiotapA')),'0a:00:00:00:0f:01','1700070000.000000',NULL,2437,1200,'0x1',1),
  (lower(hex('NoRadiotapB')),'0a:00:00:00:0f:02','1700070000.300000',NULL,2437,1201,'0x1',1);"
ssid2bursts-seq >/dev/null 2>&1
assert_eq "frames with no RSSI at all still group by sequence" "1" \
    "$(sq1 "select count(*) from bursts
             where bmethod='seq' and time='1700070000.000000' and burst_size >= 2;")"

# --- burst boundaries: gap-based vs the fixed window ---------------------
# Six frames from one MAC, each 0.8s after the last, spanning 4 seconds. It is
# one continuous burst, and BURST_SHAPE decides whether it is reported as one.
#
# The window form cuts at BURST_WINDOW seconds from whichever frame anchored the
# burst, so a run straddling that boundary is reported as several and
# burst_duration can never exceed the window -- which is why FINGERPRINTING.md
# calls burst_size and burst_duration partly artifacts of it.
chain=""
for i in 0 1 2 3 4 5; do
    chain="$chain$(printf '17000000%02d.%d|aa:bb:cc:dd:ee:ff|616161|%d\n' \
                   $((i * 8 / 10)) $(((i * 8) % 10)) $((5 + i)))"$'\n'
done

windowed=$(printf '%s' "$chain" | BURST_SHAPE=window bash -c \
    'source ./analysis-scripts/bursts_functions.sh; _bursts_group wlan_sa 1 exact')
gapped=$(printf '%s' "$chain" | BURST_SHAPE=gap bash -c \
    'source ./analysis-scripts/bursts_functions.sh; _bursts_group wlan_sa 1 exact')

assert_contains "the fixed window splits one continuous burst into several" \
    "bursts:3" "$windowed"
assert_contains "gap detection reports it as one" "bursts:1" "$gapped"
assert_contains "and recovers its true duration" "4.0000000" "$gapped"
assert_contains "and its true size" ",6," "$gapped"
assert_not_contains "which the window could never do -- it caps at BURST_WINDOW" \
    "4.0000000" "$windowed"

# Both shapes must account for every frame; neither may drop one.
assert_contains "the window shape loses no frames" "grouped:6" "$windowed"
assert_contains "the gap shape loses no frames" "grouped:6" "$gapped"

# A real silence still ends a burst -- otherwise everything from one MAC would
# collapse into a single burst spanning the whole capture.
split=$(printf '1700000000.0|aa:bb:cc:dd:ee:ff|616161|5\n1700000000.5|aa:bb:cc:dd:ee:ff|626262|6\n1700000060.0|aa:bb:cc:dd:ee:ff|636363|7\n' \
        | BURST_SHAPE=gap bash -c 'source ./analysis-scripts/bursts_functions.sh; _bursts_group wlan_sa 1 exact')
assert_contains "a gap longer than BURST_GAP ends the burst" "bursts:1" "$split"
assert_contains "and the frame after the silence is left alone" "lone:1" "$split"

# --- is_uniq ------------------------------------------------------------
is_uniq >/tmp/burst_uniq.log 2>&1
assert_eq "every burst got an is_uniq verdict" \
    "0" "$(sq1 "select count(*) from bursts where is_uniq is null;")"
assert_eq "the 4-distinct-ssid burst is marked unique" \
    "1" "$(sq1 "select is_uniq from bursts where time='$BURST_T';")"

finish
