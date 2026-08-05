#!/usr/bin/bash
# Create or migrate the probeprint schema. Safe to re-run.
#
# Tables are created with their original column set and then brought up to date
# with `add column if not exists`, so a fresh install and an existing
# collection converge on exactly the same schema.

mysql -e "create database if not exists probeprint;"

mysql probeprint -e "create table if not exists ssid(ssid_hex varchar(200), wlan_sa varchar(17), time varchar(22) primary key, rssi varchar(12), freq integer, seq integer, vht varchar(20), is_processed integer default 0, vendor text default null, tag text default null);"


mysql probeprint -e "create table if not exists ssid_intel(ssid_hex varchar(255) primary key,  location varchar(64), category varchar(32), is_name varchar(20),is_airport varchar(255), is_common integer default null, is_oneloc integer, score integer default null);"

mysql probeprint -e "create table if not exists bursts(ssids text, time varchar(22) primary key, burst_size integer, burst_duration varchar(22) default 0, related_burst integer default 0, is_uniq integer default null, bmethod varchar(20) default null);"

# ---------------------------------------------------------------------------
# Information Element fingerprinting columns.
#
# Pintor & Atzori (GLOBECOM 2022) measured IE importance for device clustering:
# IE 127 Extended Capabilities (0.34), IE 45 HT Capabilities (0.175) and
# IE 221 Vendor Specific (0.162) dominate, and DBSCAN over just those three
# clustered probe requests to the correct device ~92% of the time. IE 191 VHT
# -- the only IE this pipeline used to capture -- scored 0.073 and was present
# in only 11.1% of frames.
# ---------------------------------------------------------------------------
mysql probeprint -e "alter table ssid add column if not exists ht varchar(16) default null;"          # IE 45
mysql probeprint -e "alter table ssid add column if not exists extcap varchar(128) default null;"     # IE 127
mysql probeprint -e "alter table ssid add column if not exists vendor_oui varchar(128) default null;" # IE 221
mysql probeprint -e "alter table ssid add column if not exists ie_order varchar(128) default null;"   # IE presence + order

# The IE fingerprint proper. Generated rather than written by the ingest path
# so it can never drift out of sync with its inputs. Deliberately excludes the
# SSID and the MAC: this identifies a device model/OS build, not an individual.
mysql probeprint -e "alter table ssid add column if not exists ie_fp char(32) as (md5(concat_ws('|',coalesce(ht,''),coalesce(extcap,''),coalesce(vendor_oui,''),coalesce(ie_order,'')))) persistent;"
mysql probeprint -e "create index if not exists idx_ssid_ie_fp on ssid (ie_fp);"

# ---------------------------------------------------------------------------
# Device identity.
#
# Two different fingerprints, doing different jobs:
#
#   ssid.ie_fp    device *class* -- model and OS build. A pure hash of the IE
#                 bytes, so it is deterministic and stable, but many physical
#                 devices share one value. It is never an individual.
#
#   devices.id    device *instance* -- one row per physical device, as inferred
#                 by the sequence-number graph. Provisional by nature: clusters
#                 merge as bridging frames arrive.
#
# devices.id is a surrogate autoincrement key so it is never reused and never
# renumbered. device_key is the content-derived natural key, computed from the
# component's earliest observation, which makes it merge-stable: when two
# components join, the merged component's earliest frame is whichever component
# started first, so that component's key survives.
# ---------------------------------------------------------------------------
mysql probeprint -e "create table if not exists devices (
  id              int auto_increment primary key,
  device_key      char(16)    not null,
  alias           varchar(64) default null,
  first_seen      varchar(22) default null,
  last_seen       varchar(22) default null,
  frame_count     int         default 0,
  mac_count       int         default 0,
  ssid_count      int         default 0,
  ie_fp_distinct  int         default 0,
  vendor          varchar(64) default null,
  confidence      varchar(8)  default null,
  unique key uniq_device_key (device_key),
  unique key uniq_alias (alias)
);"

# ---------------------------------------------------------------------------
# The preferred network list: which SSIDs each device has been seen probing for.
#
# This is the point of the whole pipeline. A device fingerprint on its own says
# "this is one device"; the SSID list attached to it says *whose* device it is.
# Cunche et al. measured preferred network lists at an average of 5.34 SSIDs and
# found each one close to unique, because most SSIDs are probed by exactly one
# device. It is also the substrate for linking two devices -- and therefore two
# people -- by the rarity of the SSIDs they share.
#
# Materialised rather than derived on demand: it is read constantly by the
# display and will be read pairwise by any future linkage pass, where a
# group-by over the whole ssid table per comparison would be hopeless.
# ---------------------------------------------------------------------------
mysql probeprint -e "create table if not exists device_ssid (
  device_id   int          not null,
  ssid_hex    varchar(200) not null,
  frame_count int          default 0,
  first_seen  varchar(22)  default null,
  last_seen   varchar(22)  default null,
  primary key (device_id, ssid_hex),
  key idx_device_ssid_ssid (ssid_hex)
);"

# pnl_size  -- how many distinct networks this device asks for.
# pnl_rarity-- summed rarity of them, i.e. how identifying the list is as a
#              whole. A device probing only 'xfinitywifi' scores near zero and
#              is effectively anonymous; one probing three household SSIDs
#              scores high and is close to uniquely identifiable.
mysql probeprint -e "alter table devices add column if not exists pnl_size int default 0;"
mysql probeprint -e "alter table devices add column if not exists pnl_rarity double default null;"

# Staging table for the graph's output, joined back to assign ids in bulk.
mysql probeprint -e "create table if not exists device_stage (
  time       varchar(22) primary key,
  device_key char(16) not null,
  key idx_stage_key (device_key)
);"

mysql probeprint -e "alter table ssid add column if not exists device_id int default null;"
mysql probeprint -e "create index if not exists idx_ssid_device_id on ssid (device_id);"
mysql probeprint -e "create index if not exists idx_ssid_seq_time on ssid (seq, time);"

# Migration: device_id shipped briefly as varchar(32) holding ids of the form
# dev-000000, generated from a per-run array index. Those were not stable --
# incremental runs restarted the index at zero and reissued ids already in use,
# so unrelated devices ended up sharing one. The values are provably wrong, so
# they are cleared rather than converted; re-run standalone_seqgraph.sh to
# regenerate against the current scheme.
device_id_type=$(mysql -N probeprint -e "select data_type from information_schema.columns where table_schema='probeprint' and table_name='ssid' and column_name='device_id';")
if [ "$device_id_type" = "varchar" ]; then
	echo "MIGRATION: ssid.device_id was varchar (the unstable dev-NNNNNN scheme)."
	echo "           Those ids collided across incremental runs, so they are being"
	echo "           cleared. Re-run ./standalone_seqgraph.sh to regenerate."
	mysql probeprint -e "update ssid set device_id = null;"
	mysql probeprint -e "alter table ssid modify column device_id int default null;"
fi

# ---------------------------------------------------------------------------
# SSID rarity.
#
# Cunche et al. (WoWMoM 2012) show that linking devices by their preferred
# network lists depends on the *rarity* of the SSIDs two devices share, not on
# how many they share -- Jaccard, which ignores rarity, was their worst
# performing metric. rarity is -ln(f) where f is the SSID's share of global
# sightings in lists/ssid.csv.
# ---------------------------------------------------------------------------
mysql probeprint -e "alter table ssid_intel add column if not exists ssid_total bigint default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists rarity double default null;"

# Lookup table built from lists/ssid.csv by standalone_rarity.sh.
mysql probeprint -e "create table if not exists ssid_freq(ssid_hex varchar(255) primary key, total bigint not null);"

# The distributed client/ nodes connect as 'pi' to the central database.
# These were previously bare SQL statements outside any mysql invocation, so
# bash tried to execute `create` as a command and the user was never created.
mysql -e "create user if not exists 'pi'@'%';"
mysql -e "grant all privileges on probeprint.* to 'pi'@'%';"
