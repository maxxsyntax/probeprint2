#!/bin/bash
# Sequence-number graph: chain probe requests into devices across MAC rotation.
#
# This is the capability the old ssid2bursts-seq lacked. Its one-second window
# could group frames inside a burst but never join two bursts, so a device that
# rotated its randomised MAC in between looked like two separate devices.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
./standalone_seqgraph.sh >/tmp/seqgraph.log 2>&1

# --- the headline result: three MACs resolved to one device --------------
dev=$(sq1 "select device_id from ssid where ssid_hex=lower(hex('RoamHome')) and wlan_sa='0d:00:00:00:00:01';")
assert_eq "first burst got a device_id" "1" "$([ -n "$dev" ] && echo 1 || echo 0)"

assert_eq "all 8 frames across 3 MAC rotations are one device" "8" \
    "$(sq1 "select count(*) from ssid where device_id='$dev';")"

assert_eq "that device spans exactly 3 MAC addresses" "3" \
    "$(sq1 "select count(distinct wlan_sa) from ssid where device_id='$dev';")"

# Each rotated address must resolve to the same device.
for mac in 0d:00:00:00:00:01 0d:00:00:00:00:02 0d:00:00:00:00:03; do
    assert_eq "MAC $mac resolves to the same device" "$dev" \
        "$(sq1 "select distinct device_id from ssid where wlan_sa='$mac';")"
done

# --- and the PNL that falls out of it ------------------------------------
# Chaining the rotations together is what makes a complete preferred network
# list recoverable; per-burst it would have been three partial lists.
assert_eq "the device's full SSID set is recovered" "3" \
    "$(sq1 "select count(distinct ssid_hex) from ssid where device_id='$dev';")"

# --- an unrelated device must stay separate ------------------------------
other=$(sq1 "select distinct device_id from ssid where wlan_sa='0e:00:00:00:00:01';")
assert_eq "a device 900s away is not merged in" "1" \
    "$([ "$other" != "$dev" ] && echo 1 || echo 0)"
assert_eq "the unrelated device is its own 2-frame component" "2" \
    "$(sq1 "select count(*) from ssid where device_id='$other';")"

# --- 12-bit counter wrap --------------------------------------------------
# 4094 -> 2 is a forward distance of 4. Without modular arithmetic it looks
# like a 4092 backward jump and the chain breaks at the wrap.
wrap=$(sq1 "select distinct device_id from ssid where ssid_hex=lower(hex('WrapNet')) and seq=4090;")
assert_eq "chain survives the sequence counter wrapping" "3" \
    "$(sq1 "select count(*) from ssid where device_id='$wrap';")"
assert_eq "the post-wrap frame joined the same device" "$wrap" \
    "$(sq1 "select device_id from ssid where ssid_hex=lower(hex('WrapNet')) and seq=2;")"

# --- reporting ------------------------------------------------------------
assert_contains "run reports how many randomisations were defeated" \
    "randomisation defeated on" "$(cat /tmp/seqgraph.log)"

report=$(./standalone_seqgraph.sh --report 2>&1)
assert_contains "report lists the multi-MAC device first" "$dev" \
    "$(echo "$report" | sed -n '2p')"

# --- incremental and idempotent ------------------------------------------
before=$(sq "select time,device_id from ssid order by time;" | md5sum)
./standalone_seqgraph.sh >/dev/null 2>&1
after=$(sq "select time,device_id from ssid order by time;" | md5sum)
assert_eq "re-running assigns nothing new" "$before" "$after"

# --- alpha is respected ---------------------------------------------------
# With a 10s ceiling the 50s inter-burst gaps cannot be bridged, so the same
# data must fall apart into three separate devices.
mysql probeprint -e "update ssid set device_id=null;"
SEQGRAPH_ALPHA=10 ./standalone_seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "a 10s alpha splits the chain back into 3 devices" "3" \
    "$(sq1 "select count(distinct device_id) from ssid where wlan_sa like '0d:%';")"

finish
