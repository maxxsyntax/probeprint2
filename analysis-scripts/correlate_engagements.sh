#!/bin/bash
# Link devices ACROSS engagements, without merging them.
#
# Per-engagement grouping (seqgraph on the working tables) deliberately never
# reaches across engagements -- that cross-session chaining is what produced the
# 258k-MAC blob. But the engagement thesis is that the same person recurs at
# different events, so this pass records those links separately, in device_xref,
# and never touches a device id. Two tiers, weakest-evidence last:
#
#   static_mac  the two devices share a burned-in (non-randomized) MAC. A
#               hardware address is one physical NIC, so this is near-certain.
#   wps_uuid    they share a WPS UUID-E -- a per-device identifier that survives
#               MAC randomization. Also near-certain.
#   attributes  they share at least THREE discriminative traits: a resolved
#               location, a personal name, a specific category, the device
#               vendor, or a rare (non-common) SSID. Probabilistic, not proof;
#               the count and the shared traits are recorded so it can be judged.
#
# Common/widespread SSIDs (is_common) are excluded from every attribute, so a
# shared 'xfinitywifi' never links anyone. Only cross-engagement pairs are
# considered, stored once in canonical (a<b) order.
#
# Usage:
#   ./analysis-scripts/correlate_engagements.sh            (re)build device_xref
#   ./analysis-scripts/correlate_engagements.sh --report   show the links
set -u
[ -f .env ] && source .env

# Number of shared discriminative attributes required for an 'attributes' link.
XREF_ATTR_MIN=${XREF_ATTR_MIN:-3}
# Rarity above which an SSID counts as an identifying attribute in its own right
# (rarity is -ln(frequency); ~8 means seen in well under 0.1% of sightings).
XREF_SSID_RARITY=${XREF_SSID_RARITY:-8}

if [ "${1:-}" = "--report" ]; then
	echo "=== cross-engagement device links (device_xref) ==="
	mysql -N probeprint <<'SQL' | sed 's/^/  /'
select concat('by basis: ', basis, ' -> ', count(*)) from device_xref group by basis;
SQL
	echo "  --- strongest links ---"
	mysql -N probeprint <<'SQL' | awk -F'\t' '{printf "  %-10s %-16s#%-6s <-> %-16s#%-6s  %s\n",$1,$2,$3,$4,$5,$6}'
select basis, engagement_a, device_a, engagement_b, device_b, left(detail,60)
  from device_xref
 order by field(basis,'static_mac','wps_uuid','attributes'), match_count desc
 limit 40;
SQL
	exit 0
fi

echo "correlate_engagements start $(date +"%H:%M:%S.%3N")"
mysql probeprint -e "delete from device_xref;"

# --- tier 1a: shared burned-in MAC ----------------------------------------
# is_random mirrors the awk/seqgraph test: locally-administered => second hex
# digit in {2,6,a,e}. Anything else is a manufacturer MAC and identifies the NIC.
mysql probeprint <<'SQL'
insert ignore into device_xref
  (engagement_a, device_a, engagement_b, device_b, basis, detail, match_count)
select a.eng, a.dev, b.eng, b.dev, 'static_mac',
       left(concat(count(distinct a.wlan_sa), ' shared MAC(s): ', min(a.wlan_sa)), 255),
       count(distinct a.wlan_sa)
from ( select distinct tag eng, device_id dev, wlan_sa from ssid_master
        where device_id is not null and tag is not null
          and lower(substr(wlan_sa,2,1)) not in ('2','6','a','e') ) a
join ( select distinct tag eng, device_id dev, wlan_sa from ssid_master
        where device_id is not null and tag is not null
          and lower(substr(wlan_sa,2,1)) not in ('2','6','a','e') ) b
  on a.wlan_sa = b.wlan_sa and a.eng < b.eng
group by a.eng, a.dev, b.eng, b.dev;
SQL

# --- tier 1b: shared WPS UUID-E -------------------------------------------
mysql probeprint <<'SQL'
insert ignore into device_xref
  (engagement_a, device_a, engagement_b, device_b, basis, detail, match_count)
select a.eng, a.dev, b.eng, b.dev, 'wps_uuid',
       left(concat('WPS UUID-E: ', min(a.wps_uuid)), 255),
       count(distinct a.wps_uuid)
from ( select distinct tag eng, device_id dev, wps_uuid from ssid_master
        where device_id is not null and tag is not null
          and wps_uuid is not null and wps_uuid <> '' ) a
join ( select distinct tag eng, device_id dev, wps_uuid from ssid_master
        where device_id is not null and tag is not null
          and wps_uuid is not null and wps_uuid <> '' ) b
  on a.wps_uuid = b.wps_uuid and a.eng < b.eng
group by a.eng, a.dev, b.eng, b.dev;
SQL

# --- tier 2: three or more shared discriminative attributes ----------------
# One connection: build a temporary per-device attribute set, then self-join it
# across engagements. is_common SSIDs are excluded from every derivation.
mysql probeprint <<SQL
create temporary table device_attr (
  eng        varchar(64)  not null,
  dev        int          not null,
  attr_type  varchar(8)   not null,
  attr_value varchar(191) not null,
  primary key (eng, dev, attr_type, attr_value)
) character set utf8mb4 collate utf8mb4_general_ci;

-- a personal/family name in one of the device's SSIDs
insert ignore into device_attr
select distinct ds.engagement, ds.device_id, 'name', left(si.is_name,191)
  from device_ssid_master ds join ssid_intel si on si.ssid_hex = ds.ssid_hex
 where si.is_name is not null and si.is_name <> '' and coalesce(si.is_common,0) <> 1;

-- a single-place SSID's coordinates, quantized to ~100m
insert ignore into device_attr
select distinct ds.engagement, ds.device_id, 'loc',
       concat(round(si.lat,3), ',', round(si.lon,3))
  from device_ssid_master ds join ssid_intel si on si.ssid_hex = ds.ssid_hex
 where si.is_oneloc = 1 and si.lat is not null and coalesce(si.is_common,0) <> 1;

-- a specific category (the catch-all OTHER_UNKNOWN is not discriminative)
insert ignore into device_attr
select distinct ds.engagement, ds.device_id, 'cat', left(si.category,191)
  from device_ssid_master ds join ssid_intel si on si.ssid_hex = ds.ssid_hex
 where si.category is not null and si.category not in ('OTHER_UNKNOWN','')
   and coalesce(si.is_common,0) <> 1;

-- a rare SSID, identifying in its own right (Cunche rarity linkage)
insert ignore into device_attr
select distinct ds.engagement, ds.device_id, 'ssid', left(ds.ssid_hex,191)
  from device_ssid_master ds join ssid_intel si on si.ssid_hex = ds.ssid_hex
 where coalesce(si.is_common,0) <> 1 and si.rarity is not null
   and si.rarity >= $XREF_SSID_RARITY;

-- the device's hardware vendor
insert ignore into device_attr
select distinct engagement, id, 'vendor', left(vendor,191)
  from devices_master
 where vendor is not null and vendor not in ('','-');

insert ignore into device_xref
  (engagement_a, device_a, engagement_b, device_b, basis, detail, match_count)
select a.eng, a.dev, b.eng, b.dev, 'attributes',
       left(concat(count(*), ' shared: ',
            group_concat(concat(a.attr_type,'=',left(a.attr_value,16)) separator '; ')), 255),
       count(*)
from device_attr a
join device_attr b
  on a.attr_type = b.attr_type and a.attr_value = b.attr_value and a.eng < b.eng
group by a.eng, a.dev, b.eng, b.dev
having count(*) >= $XREF_ATTR_MIN;
SQL

echo "  links recorded:"
mysql -N probeprint <<'SQL' | sed 's/^/    /'
select concat(basis, ': ', count(*)) from device_xref group by basis;
select concat('TOTAL: ', count(*)) from device_xref;
SQL
echo "correlate_engagements stop $(date +"%H:%M:%S.%3N")"
