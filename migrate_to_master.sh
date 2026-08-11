#!/bin/bash
# One-time: seed the master archive from the pre-split single collection.
#
# Before the per-engagement split, everything lived in one ssid table with all
# grouping done across the merged corpus (the source of the 258k-MAC blob). This
# promotes that collection wholesale into the master archive under the
# engagement name 'legacy_merge' -- keeping it exactly as-is, blobbed grouping
# and all -- then empties the working tables so the next real engagement starts
# clean.
#
# Guarded and idempotent: it refuses once the master already holds rows, so a
# second run is a no-op. Run ./build_dbs.sh first to create the master tables.
#
# Usage: ./migrate_to_master.sh
set -u

LEGACY=legacy_merge

have_master=$(mysql -N probeprint <<< "select count(*) from ssid_master;" 2>/dev/null)
if [ -z "$have_master" ]; then
	echo "Master tables do not exist. Run ./build_dbs.sh first." >&2
	exit 1
fi
if [ "${have_master:-0}" -ne 0 ]; then
	echo "ssid_master already holds $have_master rows -- migration already done. Nothing to do."
	exit 0
fi

nframes=$(mysql -N probeprint <<< "select count(*) from ssid;")
if [ "${nframes:-0}" -eq 0 ]; then
	echo "Working ssid table is empty -- nothing to migrate."
	exit 0
fi

echo "migrate_to_master start $(date +"%H:%M:%S.%3N")  (promoting $nframes frames to '$LEGACY')"

# Insertable column list: everything except the generated ie_fp, intersected
# with ssid_master's columns so a not-yet-mirrored column is skipped, not fatal.
cols=$(mysql -N probeprint <<< "select group_concat(column_name order by ordinal_position)
  from information_schema.columns
 where table_schema = database() and table_name = 'ssid'
   and extra not like '%GENERATED%'
   and column_name in (select column_name from information_schema.columns
                        where table_schema = database() and table_name = 'ssid_master');")

mysql probeprint <<SQL
insert into ssid_master ($cols) select $cols from ssid;

insert into devices_master
  (engagement, id, device_key, alias, first_seen, last_seen, frame_count,
   mac_count, ssid_count, ie_fp_distinct, vendor, confidence, pnl_size, pnl_rarity)
select '$LEGACY', id, device_key, alias, first_seen, last_seen, frame_count,
       mac_count, ssid_count, ie_fp_distinct, vendor, confidence, pnl_size, pnl_rarity
  from devices;

insert into device_ssid_master
  (engagement, device_id, ssid_hex, frame_count, first_seen, last_seen)
select '$LEGACY', device_id, ssid_hex, frame_count, first_seen, last_seen
  from device_ssid;
SQL

echo "  promoted to master:"
mysql -N probeprint <<SQL | sed 's/^/    /'
select concat('frames  : ', count(*)) from ssid_master;
select concat('devices : ', count(*)) from devices_master     where engagement = '$LEGACY';
select concat('pnl rows: ', count(*)) from device_ssid_master where engagement = '$LEGACY';
SQL

# Empty the working tables for the first real engagement. ssid_intel, bssid_geo
# and ssid_freq are shared master tables and are deliberately left intact.
mysql probeprint <<'SQL'
truncate table ssid;
truncate table devices;
truncate table device_ssid;
truncate table device_stage;
truncate table seqgraph_newframes;
truncate table seqgraph_touched;
SQL
echo "  working tables emptied"
echo "migrate_to_master stop $(date +"%H:%M:%S.%3N")"
