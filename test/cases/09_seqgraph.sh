#!/bin/bash
# Sequence-number graph: chain probe requests into devices across MAC rotation.
#
# This is the capability the old ssid2bursts-seq lacked. Its one-second window
# could group frames inside a burst but never join two bursts, so a device that
# rotated its randomized MAC in between looked like two separate devices.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
./analysis-scripts/seqgraph.sh >/tmp/seqgraph.log 2>&1

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

report=$(./analysis-scripts/seqgraph.sh --report 2>&1)
# Not "first": the report sorts by pnl_rarity before mac_count, and several
# fixtures tie at 3 MACs, so position is not stable. Presence is what matters.
assert_contains "report lists the multi-MAC device" "$dev" "$report"

# --- incremental and idempotent ------------------------------------------
before=$(sq "select time,device_id from ssid order by time;" | md5sum)
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
after=$(sq "select time,device_id from ssid order by time;" | md5sum)

# --- identity is stable across incremental runs ---------------------------
# The previous scheme minted ids from a per-run array index, so an incremental
# run restarted at zero and reissued ids already in use. A device arriving later
# must get its own id, never an existing one.
before_ids=$(sq "select id, device_key from devices order by id;")
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('LateArrival')),'11:00:00:00:00:01','1700099000.000000','-50',2437,3000,'0x1'),
  (lower(hex('LateArrival')),'11:00:00:00:00:01','1700099000.100000','-50',2437,3001,'0x1');"
./analysis-scripts/seqgraph.sh >/tmp/seq_inc.log 2>&1

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
./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1
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
./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1
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
source ./analysis-scripts/seqgraph_functions.sh
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
SEQGRAPH_ALPHA=10 SEQGRAPH_GATE_IE=0 ./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "a 10s alpha splits the chain back into 3 devices" "3" \
    "$(sq1 "select count(distinct device_id) from ssid where wlan_sa in ('12:00:00:00:00:01','36:00:00:00:00:02','5a:00:00:00:00:03');")"

# --- WPS UUID-E unions across randomization, even when nothing else links --
# The UUID-E is a persistent per-device identifier that survives MAC rotation,
# so two frames with different randomized MACs and the same UUID-E must be one
# device -- as strong as a static MAC. Make the two frames impossible to link
# any other way: different randomized MACs, far apart in time (beyond ALPHA),
# sequence numbers that do not chain. Only the shared UUID-E can join them.
mysql probeprint -e "delete from ssid where ssid_hex=lower(hex('WpsNet'));"
mysql probeprint -e "delete from ssid where ssid_hex=lower(hex('WpsOther'));"
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,wps_uuid) values
  (lower(hex('WpsNet')),'6a:00:00:00:00:01','1700200000.000000','-50',2437,10,'0x1','abc123-uuid-e'),
  (lower(hex('WpsNet')),'7e:00:00:00:00:02','1700209999.000000','-50',2437,4000,'0x1','abc123-uuid-e'),
  (lower(hex('WpsOther')),'8a:00:00:00:00:03','1700400000.000000','-50',2437,2000,'0x1','different-uuid');"
./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "two randomized MACs sharing a WPS UUID-E are one device" "1" \
    "$(sq1 "select count(distinct device_id) from ssid where ssid_hex=lower(hex('WpsNet'));")"
assert_eq "and that device spans both randomized MACs" "2" \
    "$(sq1 "select count(distinct wlan_sa) from ssid where ssid_hex=lower(hex('WpsNet'));")"
# A different UUID-E must NOT be pulled into that device.
wdev=$(sq1 "select distinct device_id from ssid where wlan_sa='6a:00:00:00:00:01';")
assert_eq "a different UUID-E is not merged in" "0" \
    "$(sq1 "select count(*) from ssid where device_id='$wdev' and wps_uuid='different-uuid';")"

# An empty UUID-E is not an identifier and must never union frames.
mysql probeprint -e "delete from ssid where ssid_hex=lower(hex('NoWps'));"
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,wps_uuid) values
  (lower(hex('NoWps')),'9a:00:00:00:00:01','1700300000.000000','-50',2437,10,'0x1',NULL),
  (lower(hex('NoWps')),'ae:00:00:00:00:02','1700309999.000000','-50',2437,4000,'0x1',NULL);"
./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1
assert_eq "two unlinkable frames with no UUID-E stay separate" "2" \
    "$(sq1 "select count(distinct device_id) from ssid where ssid_hex=lower(hex('NoWps'));")"

# --- incremental grouping re-joins returning devices, does not fragment ---
# The default (non-recompute) pass groups only new (device_id null) frames, but
# a returning device must land on its EXISTING id, not a fresh one. Start clean.
reset_db
./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1

# (a) A returning STATIC MAC. Grouped in the first pass; a new frame from the
#     same burned-in MAC arrives later and must join the same device.
staticdev=$(sq1 "select distinct device_id from ssid where wlan_sa='00:11:22:00:00:01';")
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('StaticReturn')),'00:11:22:00:00:01','1700500000.000000','-50',2437,900,'0x1');"
./analysis-scripts/seqgraph.sh >/tmp/inc1.log 2>&1        # incremental
assert_eq "a returning static MAC re-joins its existing device" "$staticdev" \
    "$(sq1 "select device_id from ssid where ssid_hex=lower(hex('StaticReturn'));")"

# (b) A returning WPS UUID-E. New randomized MAC, days later, unlinkable by
#     time/seq -- only the shared UUID-E ties it to the earlier device.
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,wps_uuid) values
  (lower(hex('UuidSeed')),'c2:00:00:00:00:01','1700510000.000000','-50',2437,5,'0x1','ret-uuid-1');"
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
uuiddev=$(sq1 "select distinct device_id from ssid where ssid_hex=lower(hex('UuidSeed'));")
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht,wps_uuid) values
  (lower(hex('UuidReturn')),'d6:00:00:00:00:02','1700600000.000000','-50',2437,3000,'0x1','ret-uuid-1');"
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
assert_eq "a returning WPS UUID-E re-joins its existing device" "$uuiddev" \
    "$(sq1 "select device_id from ssid where ssid_hex=lower(hex('UuidReturn'));")"

# (c) A burst continuing within ALPHA of an already-grouped frame joins that
#     device via the lookback tail, not a new id.
base=$(sq1 "select distinct device_id from ssid where wlan_sa='12:00:00:00:00:01';")
# Continue from the device's actual last frame: 30s later (< ALPHA) and a small
# forward step in sequence (< BETA), with the same IE fingerprint.
lastt=$(sq1 "select max(cast(time as decimal(20,7))) from ssid where device_id='$base';")
predseq=$(sq1 "select seq from ssid where device_id='$base' order by cast(time as decimal(20,7)) desc limit 1;")
cont=$(printf '%.6f' "$(echo "$lastt + 30" | bc)")
contseq=$(( predseq + 10 ))
# No IE columns: an empty IE fingerprint is never blocked by the gate, so the
# frame chains on time+sequence alone. (ie_fp is a generated column and cannot
# be inserted into anyway.)
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('RoamHome')),'12:00:00:00:00:01','$cont','-50',2437,$contseq,'0x1');"
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
assert_eq "a burst continuing within ALPHA joins the recent device" "$base" \
    "$(sq1 "select device_id from ssid where ssid_hex=lower(hex('RoamHome')) and time='$cont';")"

# (d) A genuinely unrelated new frame gets its OWN new device, not merged.
before_devs=$(sq1 "select count(*) from devices;")
mysql probeprint -e "insert into ssid (ssid_hex,wlan_sa,time,rssi,freq,seq,vht) values
  (lower(hex('Stranger')),'fa:00:00:00:00:09','1700900000.000000','-50',2437,50,'0x1');"
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
assert_eq "an unrelated new frame gets its own id" "1" \
    "$(sq1 "select count(*) > 0 from ssid where ssid_hex=lower(hex('Stranger')) and device_id is not null;")"
assert_eq "and does not join any pre-existing device" "1" \
    "$(sq1 "select count(distinct device_id) from ssid where ssid_hex=lower(hex('Stranger'));")"

finish