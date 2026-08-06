#!/bin/bash
# Sequence-number graph: chain probe requests into devices across MAC rotation.
#
# This is the capability the old ssid2bursts-seq lacked. Its one-second window
# could group frames inside a burst but never join two bursts, so a device that
# rotated its randomized MAC in between looked like two separate devices.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
./standalone_seqgraph.sh >/tmp/seqgraph.log 2>&1

# --- the headline result: three MACs resolved to one device --------------
dev=$(sq1 "select device_id from ssid where ssid_hex=lower(hex('RoamHome')) and wlan_sa='12:00:00:00:00:01';")
assert_eq "first burst got a device_id" "1" "$([ -n "$dev" ] && echo 1 || echo 0)"
assert_eq "device_id is an integer surrogate key" "1" \
    "$(printf '%s' "$dev" | grep -qE '^[0-9]+$' && echo 1 || echo 0)"

assert_eq "all 8 frames across 3 MAC rotations are one device" "8" \
    "$(sq1 "select count(*) from ssid where device_id='$dev';")"

assert_eq "that device spans exactly 3 MAC addresses" "3" \
    "$(sq1 "select count(distinct wlan_sa) from ssid where device_id='$dev';")"

# Each rotated address must resolve to the same device.
for mac in 12:00:00:00:00:01 36:00:00:00:00:02 5a:00:00:00:00:03; do
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
assert_contains "run reports how many randomizations were defeated" \
    "randomization defeated on" "$(cat /tmp/seqgraph.log)"

report=$(./standalone_seqgraph.sh --report 2>&1)
assert_contains "report lists the multi-MAC device first" "$dev" \
    "$(echo "$report" | sed -n '2p')"

# --- incremental and idempotent ------------------------------------------
before=$(sq "select time,device_id from ssid order by time;" | md5sum)
./standalone_seqgraph.sh >/dev/null 2>&1
after=$(sq "select time,device_id from ssid order by time;" | md5sum)

# --- identity is stable across incremental runs ---------------------------
# The previous scheme minted ids from a per-run array index, so an incremental
# run restarted at zero and reissued ids already in use. A device arriving later
# must get its own id, never an existing one.
before_ids=$(sq "select id, device_key from devices order by id;")
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('LateArrival')),'11:00:00:00:00:01','1700099000.000000','-50',2437,3000,'0x1'),
  (lower(hex('LateArrival')),'11:00:00:00:00:01','1700099000.100000','-50',2437,3001,'0x1');"
./standalone_seqgraph.sh >/tmp/seq_inc.log 2>&1

late=$(sq1 "select distinct device_id from ssid where ssid_hex=lower(hex('LateArrival'));")
assert_eq "a late-arriving device gets its own id, not a reused one" "1" \
    "$(sq1 "select count(*) = 1 from ssid where device_id = $late;" >/dev/null; \
       sq1 "select count(distinct ssid_hex) = 1 from ssid where device_id = $late;")"
assert_eq "the late device did not collide with the roaming device" "1" \
    "$([ "$late" != "$dev" ] && echo 1 || echo 0)"

# Pre-existing devices keep the exact ids they already had.
assert_eq "existing device ids are unchanged by the new run" \
    "$before_ids" "$(sq "select id, device_key from devices where id <= (select max(id) from devices where id < $late) order by id;")"

# --- device_key is merge-stable and reproducible --------------------------
# Derived from the component's earliest observation, so a full recompute must
# reproduce exactly the same keys.
keys_before=$(sq "select device_key from devices order by device_key;" | md5sum)
mysql probeprint -e "update ssid set device_id=null;"
./standalone_seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "recompute reproduces identical device keys" \
    "$keys_before" "$(sq "select device_key from devices order by device_key;" | md5sum)"

# --- alias is a non-key attribute -----------------------------------------
assert_eq "every device has an alias" "0" \
    "$(sq1 "select count(*) from devices where alias is null;")"
assert_eq "aliases are unique" "1" \
    "$(sq1 "select count(distinct alias) = count(*) from devices;")"
assert_eq "alias looks like Adjective Noun" "1" \
    "$(sq1 "select alias from devices where id = $dev;" | grep -qE '^[A-Z][a-z]+ [A-Z][a-z]+( [0-9]+)?$' && echo 1 || echo 0)"

# The alias must be a function of device_key, not of insertion order, so a
# recompute must not rename anything.
alias_before=$(sq1 "select alias from devices where id = $dev;")
mysql probeprint -e "update ssid set device_id=null;"
./standalone_seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "recompute does not rename a device" \
    "$alias_before" "$(sq1 "select alias from devices where id = $dev;")"

# --- confidence flags the false-merge mode --------------------------------
# One physical device cannot change its IE signature mid-capture, so a component
# spanning several ie_fp values is a suspected false merge.
# The roaming device's eight frames all carry one IE signature, so the merge
# across three MACs is corroborated rather than merely asserted.
assert_eq "consistent IEs across the merge means high confidence" "high" \
    "$(sq1 "select confidence from devices where id = $dev;")"
assert_eq "and exactly one IE signature was seen" "1" \
    "$(sq1 "select ie_fp_distinct from devices where id = $dev;")"

# Force an inconsistency: give one frame of a device a different IE signature.
mysql probeprint -e "update ssid set ie_order='0,1,45' , extcap='0xff'
                      where device_id = $dev limit 1;"
mysql probeprint -e "update ssid set ie_order='0,1,45,127' , extcap='0x01'
                      where device_id = $dev and ie_order is null limit 1;"
source ./seqgraph_functions.sh
seqgraph_refresh_stats
assert_eq "mixed IE signatures downgrade confidence to low" "low" \
    "$(sq1 "select confidence from devices where id = $dev;")"


assert_eq "re-running assigns nothing new" "$before" "$after"

# --- alpha is respected ---------------------------------------------------
# With a 10s ceiling the 50s inter-burst gaps cannot be bridged, so the same
# data must fall apart into three separate devices -- one per burst.
#
# Gating is switched off so this measures alpha alone. The confidence test above
# deliberately rewrote one frame's IE signature, and with gating on that frame
# would correctly split off on its own, giving four devices for a reason that
# has nothing to do with alpha.
mysql probeprint -e "update ssid set device_id=null;"
SEQGRAPH_ALPHA=10 SEQGRAPH_GATE_IE=0 ./standalone_seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "a 10s alpha splits the chain back into 3 devices" "3" \
    "$(sq1 "select count(distinct device_id) from ssid where wlan_sa in ('12:00:00:00:00:01','36:00:00:00:00:02','5a:00:00:00:00:03');")"


finish