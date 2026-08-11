#!/bin/bash
# Fold the current engagement's working tables into the master archive.
#
# Capture and all grouping run on the working tables (ssid / devices /
# device_ssid), which hold ONE engagement at a time so seqgraph stays bounded
# (see build_dbs.sh). When an engagement ends, this appends its frames and its
# device grouping into the master archive -- namespaced by engagement so nothing
# ever re-groups across engagements -- and truncates the working tables for the
# next one.
#
# Usage:
#   ./analysis-scripts/fold_engagement.sh [engagement]
#
# The engagement name namespaces the folded rows. It defaults to $ENGAGEMENT,
# then to the single distinct tag found in the working ssid table. Fold is
# idempotent: re-folding the same engagement replaces its master rows rather
# than duplicating them.
#
# ssid_intel, bssid_geo and ssid_freq are shared master tables, not per
# engagement, so they are deliberately left untouched here.
set -u
[ -f .env ] && source .env

eng="${1:-${ENGAGEMENT:-}}"

# Fall back to the tag the working frames actually carry. A working table should
# hold exactly one engagement; if it holds several (someone captured twice
# without folding), refuse rather than guess a namespace for mixed data.
tags=$(mysql -N probeprint <<< "select count(distinct tag) from ssid where tag is not null;")
if [ -z "$eng" ]; then
	if [ "${tags:-0}" -eq 1 ]; then
		eng=$(mysql -N probeprint <<< "select tag from ssid where tag is not null limit 1;")
	else
		echo "No engagement given and the working ssid table holds $tags distinct tags." >&2
		echo "Pass the name explicitly: ./analysis-scripts/fold_engagement.sh <engagement>" >&2
		exit 1
	fi
fi

nframes=$(mysql -N probeprint <<< "select count(*) from ssid;")
if [ "${nframes:-0}" -eq 0 ]; then
	echo "Working ssid table is empty -- nothing to fold."
	exit 0
fi

echo "fold_engagement '$eng' start $(date +"%H:%M:%S.%3N")  ($nframes frames)"

# The insertable columns: everything except the generated ie_fp (the master
# recomputes it), AND present in ssid_master too. Intersecting with the master's
# columns means a column added to the working ssid but not yet mirrored to
# ssid_master is skipped rather than crashing the fold with 'Unknown column'.
cols=$(mysql -N probeprint <<< "select group_concat(column_name order by ordinal_position)
  from information_schema.columns
 where table_schema = database() and table_name = 'ssid'
   and extra not like '%GENERATED%'
   and column_name in (select column_name from information_schema.columns
                        where table_schema = database() and table_name = 'ssid_master');")

# Delete-then-insert per engagement, so a re-fold replaces rather than
# duplicates. The legacy pre-split archive carries tag NULL and engagement
# 'legacy_merge', so a named engagement never touches it.
mysql probeprint <<SQL
delete from ssid_master        where tag        = '$eng';
delete from devices_master     where engagement = '$eng';
delete from device_ssid_master where engagement = '$eng';

insert ignore into ssid_master ($cols) select $cols from ssid;

insert ignore into devices_master
  (engagement, id, device_key, alias, first_seen, last_seen, frame_count,
   mac_count, ssid_count, ie_fp_distinct, vendor, confidence, pnl_size, pnl_rarity)
select '$eng', id, device_key, alias, first_seen, last_seen, frame_count,
       mac_count, ssid_count, ie_fp_distinct, vendor, confidence, pnl_size, pnl_rarity
  from devices;

insert ignore into device_ssid_master
  (engagement, device_id, ssid_hex, frame_count, first_seen, last_seen)
select '$eng', device_id, ssid_hex, frame_count, first_seen, last_seen
  from device_ssid;
SQL

echo "  folded into master:"
mysql -N probeprint <<SQL | sed 's/^/    /'
select concat('frames  : ', count(*)) from ssid_master        where tag        = '$eng';
select concat('devices : ', count(*)) from devices_master     where engagement = '$eng';
select concat('pnl rows: ', count(*)) from device_ssid_master where engagement = '$eng';
SQL

# Reset the working tables (and the seqgraph scratch) for the next engagement.
mysql probeprint <<'SQL'
truncate table ssid;
truncate table devices;
truncate table device_ssid;
truncate table device_stage;
truncate table seqgraph_newframes;
truncate table seqgraph_touched;
SQL

echo "  working tables reset for the next engagement"
echo "fold_engagement '$eng' stop $(date +"%H:%M:%S.%3N")"
