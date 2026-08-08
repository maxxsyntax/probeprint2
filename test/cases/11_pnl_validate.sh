#!/bin/bash
# The preferred network list attached to each device fingerprint, and the
# accuracy harness that scores the clustering against ground truth.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
./analysis-scripts/seqgraph.sh >/dev/null 2>&1
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) select distinct ssid_hex from ssid;"
./analysis-scripts/rarity.sh   >/dev/null 2>&1
./analysis-scripts/seqgraph.sh --pnl >/dev/null 2>&1

dev=$(sq1 "select distinct device_id from ssid where ssid_hex=lower(hex('RoamHome'));")

# --- the SSID list is attached to the fingerprint -------------------------
assert_eq "the roaming device's PNL has all 3 networks" "3" \
    "$(sq1 "select count(*) from device_ssid where device_id = $dev;")"

for net in RoamHome RoamCafe RoamWork; do
    assert_eq "PNL contains $net" "1" \
        "$(sq1 "select count(*) from device_ssid where device_id = $dev and ssid_hex = lower(hex('$net'));")"
done

# The PNL survives MAC rotation -- that is the whole reason it is keyed on the
# device rather than on wlan_sa. Keyed by MAC it would be three partial lists.
assert_eq "PNL is complete despite 3 MAC rotations" "3" \
    "$(sq1 "select mac_count from devices where id = $dev;")"

# Per-network provenance, not just membership.
assert_eq "each PNL entry records how many frames it came from" "0" \
    "$(sq1 "select count(*) from device_ssid where frame_count < 1;")"
assert_eq "each PNL entry records a first/last seen" "0" \
    "$(sq1 "select count(*) from device_ssid where first_seen is null or last_seen is null;")"

# The wildcard sentinel is not a preference and must not pollute any list.
assert_eq "the <MISSING> sentinel is excluded from every PNL" "0" \
    "$(sq1 "select count(*) from device_ssid where ssid_hex = '<MISSING>';")"

# --- pnl_size and pnl_rarity ---------------------------------------------
assert_eq "pnl_size matches the device_ssid rows" "1" \
    "$(sq1 "select (select pnl_size from devices where id = $dev)
                 = (select count(*) from device_ssid where device_id = $dev);")"

# pnl_rarity is how identifying the whole list is. Three invented SSIDs are
# absent from the WiGLE corpus, so each scores maximum rarity (~19.7) and the
# list total should be far above a device probing only common networks.
assert_eq "pnl_rarity is the summed rarity of the list" "1" \
    "$(sq1 "select round((select pnl_rarity from devices where id = $dev), 2)
                 = round((select sum(i.rarity) from device_ssid ds
                            join ssid_intel i on i.ssid_hex = ds.ssid_hex
                           where ds.device_id = $dev), 2);")"
assert_eq "a list of 3 unseen SSIDs is highly identifying" "1" \
    "$(sq1 "select pnl_rarity > 50 from devices where id = $dev;")"

# A device probing only a carrier hotspot is nearly anonymous by comparison.
xf=$(sq1 "select distinct device_id from ssid where ssid_hex=lower(hex('xfinitywifi'));")
assert_eq "a device probing only a common SSID scores far lower" "1" \
    "$(sq1 "select (select pnl_rarity from devices where id = $xf)
                 < (select pnl_rarity from devices where id = $dev);")"

# --- ground-truth validation ---------------------------------------------
# GroundTruthA and GroundTruthB are two different physical devices with
# globally-unique MACs, interleaved in time with consecutive sequence numbers.
a=$(sq1 "select distinct device_id from ssid where wlan_sa='00:11:22:00:00:01';")
b=$(sq1 "select distinct device_id from ssid where wlan_sa='00:33:44:00:00:01';")

assert_eq "IE gating keeps two interleaved real devices apart" "1" \
    "$([ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] && echo 1 || echo 0)"

report=$(./analysis-scripts/seqgraph.sh --validate 2>&1)
assert_contains "validation counts the static MACs as ground truth" \
    "ground-truth devices" "$report"
assert_contains "validation reports no false merges when gating is on" \
    "FALSE MERGES (>1 static MAC per cluster)   : 0" "$report"
assert_contains "validation reports no false splits" \
    "FALSE SPLITS (1 static MAC over >1 cluster): 0" "$report"
assert_contains "a clean run says so plainly" "clean: no measurable error" "$report"

# --- and the harness genuinely detects a bad merge ------------------------
# With gating disabled the same data merges the two devices, which is the
# failure the harness exists to surface. If this passes with gating off, the
# harness is measuring nothing.
mysql probeprint -e "update ssid set device_id = null; delete from devices; delete from device_ssid;"
SEQGRAPH_GATE_IE=0 ./analysis-scripts/seqgraph.sh --recompute >/dev/null 2>&1

# Ungated, the interleaving produces both error kinds at once: one cluster ends
# up holding frames from both devices (merge), while one device's own frames are
# scattered across two clusters (split). Assert the merge directly rather than
# comparing scalars -- `select distinct device_id` returns several rows once a
# split exists, which errors instead of failing cleanly.
assert_eq "without gating, one cluster holds both real devices" "1" \
    "$(sq1 "select count(*) > 0 from (
              select device_id from ssid
               where wlan_sa in ('00:11:22:00:00:01','00:33:44:00:00:01')
               group by device_id having count(distinct wlan_sa) > 1) x;")"

# A non-randomized MAC can no longer be split, gated or not: seqgraph_assign
# unions frames sharing one before any inference runs, because a globally
# administered address identifies the device outright. Measured against
# labelled ground truth, the absence of that union was severe -- one device
# that never rotated its address came out as 137 separate devices.
assert_eq "a static MAC is never scattered, even ungated" "0" \
    "$(sq1 "select count(*) from (
              select wlan_sa from ssid
               where wlan_sa in ('00:11:22:00:00:01','00:33:44:00:00:01')
               group by wlan_sa having count(distinct device_id) > 1) x;")"

ungated=$(SEQGRAPH_GATE_IE=0 ./analysis-scripts/seqgraph.sh --validate 2>&1)
assert_contains "the harness detects the false merge" \
    "FALSE MERGES (>1 static MAC per cluster)   : 1" "$ungated"
assert_contains "and names the MACs it wrongly combined" "00:11:22:00:00:01" "$ungated"
assert_contains "and suggests the remedy" "SEQGRAPH_GATE_IE=1" "$ungated"
assert_not_contains "and does not call a broken run clean" \
    "clean: no measurable error" "$ungated"

# The split detector still has to work -- it is the only guard against a future
# change reintroducing the fragmentation. The graph can no longer produce one,
# so construct it directly and check the validator still sees it.
mysql probeprint -e "update ssid set device_id = 999999
                      where wlan_sa = '00:11:22:00:00:01'
                      order by time limit 1;"
forced=$(./analysis-scripts/seqgraph.sh --validate 2>&1)
assert_contains "the split detector still fires when a split is present" \
    "FALSE SPLITS (1 static MAC over >1 cluster): 1" "$forced"
assert_contains "and names the device it was scattered across" \
    "00:11:22:00:00:01" "$forced"

finish
