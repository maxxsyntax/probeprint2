#!/usr/bin/bash
# Create or migrate the probeprint schema. Safe to re-run.
#
# Tables are created with their original column set and then brought up to date
# with `add column if not exists`, so a fresh install and an existing
# collection converge on exactly the same schema.

# Every table is pinned to one collation, explicitly.
#
# MariaDB 11.x changed the utf8mb4 default from utf8mb4_general_ci to
# utf8mb4_uca1400_ai_ci. Tables restored from a dump taken on an older server
# keep general_ci, while any table created here without an explicit collation
# picks up the new server default. Joining a varchar across the two then fails
# outright:
#
#   ERROR 1267: Illegal mix of collations (utf8mb4_general_ci,IMPLICIT)
#               and (utf8mb4_uca1400_ai_ci,IMPLICIT) for operation '='
#
# which silently breaks `update ssid join device_stage on s.time = t.time` and
# leaves every frame unassigned. general_ci is the target because that is what
# the existing collections use; the values involved are hex, MAC addresses and
# numeric strings, so the ordering rules are irrelevant -- only agreement is.
DB_COLLATE="character set utf8mb4 collate utf8mb4_general_ci"

mysql -e "create database if not exists probeprint;"

mysql probeprint -e "create table if not exists ssid(ssid_hex varchar(200), wlan_sa varchar(17), time varchar(22) primary key, rssi varchar(12), freq integer, seq integer, vht varchar(20), is_processed integer default 0, vendor text default null, tag text default null) $DB_COLLATE;"


mysql probeprint -e "create table if not exists ssid_intel(ssid_hex varchar(255) primary key,  location varchar(64), category varchar(32), is_name varchar(20),is_airport varchar(255), is_common integer default null, is_oneloc integer, score integer default null) $DB_COLLATE;"

mysql probeprint -e "create table if not exists bursts(ssids text, time varchar(22) primary key, burst_size integer, burst_duration varchar(22) default 0, related_burst integer default 0, is_uniq integer default null, bmethod varchar(20) default null) $DB_COLLATE;"

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

# Fingerprinting fields added after the first schema (FINGERPRINTING.md). WPS
# UUID-E is a per-device identifier that survives MAC randomization -- its own
# column, an instance ID, not part of the class fingerprint. The HT-Capabilities
# subfields are high-entropy and hardware-stable; they sharpen ie_fp.
mysql probeprint -e "alter table ssid add column if not exists wps_uuid varchar(64) default null;"
mysql probeprint -e "alter table ssid add column if not exists ht_ampdu  varchar(24) default null;"
mysql probeprint -e "alter table ssid add column if not exists ht_mcsset varchar(64) default null;"
mysql probeprint -e "alter table ssid add column if not exists txbf      varchar(32) default null;"
mysql probeprint -e "alter table ssid add column if not exists asel      varchar(16) default null;"
# frame.len: total on-wire probe length, a coarse model-level feature. Its own
# column, not part of ie_fp (it is derived from the same IE set ie_fp hashes).
mysql probeprint -e "alter table ssid add column if not exists frame_len integer default null;"

# The IE fingerprint proper. Generated rather than written by the ingest path
# so it can never drift out of sync with its inputs. Deliberately excludes the
# SSID and the MAC: this identifies a device model/OS build, not an individual.
# The HT subfields (ampdu/mcsset/txbf/asel) are folded in; WPS UUID-E is not --
# it is an individual identifier, not a class feature.
#
# ie_fp is a persistent generated column, so its expression cannot be changed by
# "add if not exists" once it exists. Migrate in place: if an older definition
# is present (one that does not yet reference ht_mcsset), drop and recreate it.
# Safe because it is derived data -- the recompute is the cost of the migration.
IE_FP_EXPR="md5(concat_ws('|',coalesce(ht,''),coalesce(extcap,''),coalesce(vendor_oui,''),coalesce(ie_order,''),coalesce(ht_ampdu,''),coalesce(ht_mcsset,''),coalesce(txbf,''),coalesce(asel,'')))"
stale=$(mysql -N probeprint -e "select count(*) from information_schema.columns
  where table_schema=database() and table_name='ssid' and column_name='ie_fp'
    and generation_expression not like '%ht_mcsset%';" 2>/dev/null)
if [ "${stale:-0}" = "1" ]; then
	echo "migrating ie_fp to include HT subfields"
	mysql probeprint -e "drop index if exists idx_ssid_ie_fp on ssid;"
	mysql probeprint -e "alter table ssid drop column ie_fp;"
fi
mysql probeprint -e "alter table ssid add column if not exists ie_fp char(32) as ($IE_FP_EXPR) persistent;"
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
) $DB_COLLATE;"

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
# Materialized rather than derived on demand: it is read constantly by the
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
) $DB_COLLATE;"

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
) $DB_COLLATE;"

# Incremental seqgraph scratch: the frames a run must (re)assign, and the devices
# it therefore touched. Scoping the PNL/stats rebuild to the touched set is what
# keeps an incremental run from re-aggregating the whole ssid table every sweep.
mysql probeprint -e "create table if not exists seqgraph_newframes (
  time varchar(22) primary key
) $DB_COLLATE;"
mysql probeprint -e "create table if not exists seqgraph_touched (
  device_id int primary key
) $DB_COLLATE;"

# Import table for the offline WiGLE exports (WigleWifi_*.csv[.gz]). One row per
# WIFI observation; geo_from_wigle_csv rebuilds it each run and resolves SSIDs
# and directed-probe BSSIDs from it, entirely offline. ssid_hex is indexed for
# the join to ssid_intel, bssid for the join to bssid_geo.
mysql probeprint -e "create table if not exists wigle_import (
  ssid_hex varchar(255),
  bssid    varchar(17),
  lat      double,
  lon      double,
  key idx_wigle_ssid  (ssid_hex),
  key idx_wigle_bssid (bssid)
) $DB_COLLATE;"

mysql probeprint -e "alter table ssid add column if not exists device_id int default null;"
mysql probeprint -e "create index if not exists idx_ssid_device_id on ssid (device_id);"
mysql probeprint -e "create index if not exists idx_ssid_seq_time on ssid (seq, time);"

# Migration: device_id shipped briefly as varchar(32) holding ids of the form
# dev-000000, generated from a per-run array index. Those were not stable --
# incremental runs restarted the index at zero and reissued ids already in use,
# so unrelated devices ended up sharing one. The values are provably wrong, so
# they are cleared rather than converted; re-run ./analysis-scripts/seqgraph.sh to
# regenerate against the current scheme.
device_id_type=$(mysql -N probeprint -e "select data_type from information_schema.columns where table_schema='probeprint' and table_name='ssid' and column_name='device_id';")
if [ "$device_id_type" = "varchar" ]; then
	echo "MIGRATION: ssid.device_id was varchar (the unstable dev-NNNNNN scheme)."
	echo "           Those ids collided across incremental runs, so they are being"
	echo "           cleared. Re-run ./analysis-scripts/seqgraph.sh to regenerate."
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

# ---------------------------------------------------------------------------
# Coordinates.
#
# The WiGLE responses cached in locs/ carry trilat/trilong for every match, but
# summarize_one only ever extracted country/region/city/road and flattened them
# into a text string -- the coordinates were fetched and thrown away. These
# columns keep them, which is what makes any spatial analysis possible at all.
#
# geo_source records which provider the fix came from, because they answer
# different questions and are not interchangeable. See geolocate_functions.sh.
# ---------------------------------------------------------------------------
mysql probeprint -e "alter table ssid_intel add column if not exists lat double default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists lon double default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists geo_source varchar(16) default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists geo_accuracy int default null;"

# How many WiGLE results matched the SSID *case-sensitively*.
#
# WiGLE's search is case-insensitive, so a query for "MyNet" also returns
# "mynet" and "MYNET" -- which are different networks in different places. A
# probe request carries one exact byte string, so only an exact-case result is
# actually the network the device asked for.
#
#   geo_match_count = 1   exactly one network has this name. Its coordinates
#                         are that AP's, and this is the definitive case.
#   geo_match_count > 1   several distinct APs share the exact name; a fix is
#                         only meaningful if they sit close together.
#   geo_match_count = 0   WiGLE knows the name only in other letter cases.
#
# ssid_intel.is_oneloc is now derived from this column rather than from WiGLE's
# case-insensitive totalResults, so the two always agree; see derive_is_oneloc
# in geolocate_functions.sh. Rows written by the old heuristic are stale until
# ./analysis-scripts/oneloc.sh --recompute has run.
mysql probeprint -e "alter table ssid_intel add column if not exists geo_match_count int default null;"

# is_cracked: this SSID's WPA password is publicly known (present in
# lists/cracked.txt). A device probing for such a network is a soft target --
# the password can be looked up, so the network can be impersonated to draw the
# device onto it. Set by the cracked pass; null until it has run.
mysql probeprint -e "alter table ssid_intel add column if not exists is_cracked integer default null;"

# ---------------------------------------------------------------------------
# Which operator's equipment a TECH_CPE SSID belongs to, from lists/cpe_isp.txt.
#
# cpe_scope says how much the match is worth, and exists so a claim is never
# stronger than the evidence:
#   country   one national market -- the strongest residential-origin signal
#             this pipeline produces
#   region    one operator across several markets
#   global    present in too many markets to narrow
#   vendor    a hardware manufacturer, carrying NO geography. Recorded so a
#             NETGEAR router is never read as evidence of a location.
#   academic  not CPE, but a strong affiliation signal (eduroam)
# ---------------------------------------------------------------------------
mysql probeprint -e "alter table ssid_intel add column if not exists cpe_isp varchar(48) default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists cpe_country varchar(64) default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists cpe_scope varchar(8) default null;"
mysql probeprint -e "create index if not exists idx_ssid_intel_cpe on ssid_intel (cpe_scope, cpe_country);"

# Language of the SSID text, kept separate from category because the two are
# orthogonal -- "Familie Mueller" is a household AND German. lang_scope says
# whether the evidence names one language, only a family of them, or is merely
# suggestive. See language_functions.sh.
mysql probeprint -e "alter table ssid_intel add column if not exists lang varchar(32) default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists lang_scope varchar(10) default null;"
mysql probeprint -e "create index if not exists idx_ssid_intel_lang on ssid_intel (lang_scope, lang);"
mysql probeprint -e "alter table ssid_intel add column if not exists street_address varchar(255) default null;"
mysql probeprint -e "create index if not exists idx_ssid_intel_geo on ssid_intel (lat, lon);"

# The destination address. On an undirected probe this is the broadcast address,
# but a *directed* probe -- for a hidden network, or an AP the device knows --
# carries the target AP's BSSID. That is the only way a BSSID ever appears in
# probe-request data, and BSSIDs are what every WiFi positioning service other
# than WiGLE is keyed on.
mysql probeprint -e "alter table ssid add column if not exists wlan_da varchar(17) default null;"
mysql probeprint -e "create index if not exists idx_ssid_wlan_da on ssid (wlan_da);"

# BSSIDs harvested from directed probes, and where they resolve to.
mysql probeprint -e "create table if not exists bssid_geo (
  bssid          varchar(17) primary key,
  ssid_hex       varchar(200) default null,
  lat            double      default null,
  lon            double      default null,
  geo_accuracy   int         default null,
  geo_source     varchar(16) default null,
  street_address varchar(255) default null,
  probe_count    int         default 0,
  first_seen     varchar(22) default null,
  last_seen      varchar(22) default null
) $DB_COLLATE;"

# Lookup table built from lists/ssid.csv by ./analysis-scripts/rarity.sh.
mysql probeprint -e "create table if not exists ssid_freq(ssid_hex varchar(255) primary key, total bigint not null) $DB_COLLATE;"

# ---------------------------------------------------------------------------
# Google Places lookup: an SSID that names a business, resolved to that
# business's address.
#
# This is a DIFFERENT KIND OF CLAIM from the WiGLE columns, and the distinction
# is the whole reason these are separate. WiGLE says "an access point with this
# SSID was observed at these coordinates" -- a measurement. Places says "a venue
# with this name is at this address", and that location only transfers to the
# device if the SSID really is that venue's network. That is an inference, and
# it is wrong for every SSID that merely borrows a business name.
#
#   place_match_count  candidates whose name matched after normalization.
#                      NULL = never queried, which is what drives the pass.
#                      0 = asked, nothing matched. 1 = the definitive case.
#   place_name         what Google actually called the match, kept so that a
#                      wrong match can be recognized as wrong afterwards.
#
# Coordinates go in lat/lon with geo_source = 'google_places', so anything
# needing observations only can filter on geo_source instead of joining a
# second set of columns. Do not read a google_places row as a sighting.
mysql probeprint -e "alter table ssid_intel add column if not exists place_match_count int default null;"
mysql probeprint -e "alter table ssid_intel add column if not exists place_name varchar(128) default null;"

# ---------------------------------------------------------------------------
# Converge the collation of any table that already existed.
#
# `create table if not exists` does nothing to a table that is already there, so
# pinning the collation above only helps fresh installs. A collection restored
# from a dump, or created before this change, keeps whatever it had -- and one
# mismatched table is enough to break every string join against it.
#
# Only tables that actually differ are touched; converting within utf8mb4
# changes the collation, not the encoding, so no data is rewritten or lost.
# ---------------------------------------------------------------------------
for t in ssid ssid_intel bursts devices device_ssid device_stage ssid_freq bssid_geo; do
	current=$(mysql -N probeprint -e "select table_collation from information_schema.tables where table_schema='probeprint' and table_name='$t';" 2>/dev/null)
	if [ -n "$current" ] && [ "$current" != "utf8mb4_general_ci" ]; then
		echo "COLLATION: $t is $current, converting to utf8mb4_general_ci"
		mysql probeprint -e "alter table \`$t\` convert to $DB_COLLATE;"
	fi
done

# The distributed client/ nodes connect as 'pi' to the central database.
# These were previously bare SQL statements outside any mysql invocation, so
# bash tried to execute `create` as a command and the user was never created.
mysql -e "create user if not exists 'pi'@'%';"
mysql -e "grant all privileges on probeprint.* to 'pi'@'%';"

# ---------------------------------------------------------------------------
# Per-engagement working tables vs the master archive.
#
# seqgraph's sequence/time linkage assumes ONE continuous capture. Run over a
# corpus of many merged captures it chains unrelated sessions into giant false
# devices (one such cluster spanned two years and 258k MACs). So capture and all
# grouping run on the WORKING tables -- ssid / devices / device_ssid -- which
# hold only the current engagement, keeping seqgraph bounded and fast. Between
# engagements, fold_engagement.sh appends the working rows into the MASTER
# archive below, namespaced by engagement, then truncates the working tables for
# the next one. seqgraph NEVER runs on the master.
#
# This block is at the very END of build_dbs.sh on purpose: `create table
# ssid_master like ssid` copies the schema as it stands at that line, so it must
# come after EVERY `alter table ssid add column` above (wlan_da among them, added
# late). A working-table column added later must be mirrored into ssid_master, so
# fold_engagement.sh folds only columns present in both tables to stay safe.
#
# ssid_master mirrors the working ssid; a frame folds in with its device_id
# intact, and the engagement is carried by the existing `tag` column. time stays
# the primary key -- a cross-engagement timestamp collision drops one frame on
# fold via insert-ignore, which is acceptable and matches the ingest path.
mysql probeprint -e "create table if not exists ssid_master like ssid;"

# devices_master and device_ssid_master are keyed by (engagement, id): each
# engagement autoincrements its own device ids from 1, so the engagement is what
# makes them unique in the archive. The working tables' single-column unique keys
# on id/device_key/alias would collide across engagements and are NOT reproduced.
mysql probeprint -e "create table if not exists devices_master (
  engagement      varchar(64) not null,
  id              int         not null,
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
  pnl_size        int         default 0,
  pnl_rarity      double      default null,
  primary key (engagement, id),
  key idx_dm_key    (engagement, device_key),
  key idx_dm_vendor (vendor)
) $DB_COLLATE;"

mysql probeprint -e "create table if not exists device_ssid_master (
  engagement  varchar(64)  not null,
  device_id   int          not null,
  ssid_hex    varchar(200) not null,
  frame_count int          default 0,
  first_seen  varchar(22)  default null,
  last_seen   varchar(22)  default null,
  primary key (engagement, device_id, ssid_hex),
  key idx_dsm_ssid (ssid_hex)
) $DB_COLLATE;"

# Cross-engagement device links. NOT a merge: device identities stay per
# engagement, and this only records that two of them are probably the same
# device or person. basis says why -- a shared burned-in MAC or WPS UUID-E is a
# hardware identity ('static_mac'/'wps_uuid'); 'attributes' means they shared at
# least three discriminative traits (a location, a name, a category, a vendor, a
# rare SSID). Pairs are stored in a canonical order (a < b) so each appears once.
mysql probeprint -e "create table if not exists device_xref (
  engagement_a varchar(64) not null,
  device_a     int         not null,
  engagement_b varchar(64) not null,
  device_b     int         not null,
  basis        varchar(16) not null,
  detail       varchar(255) default null,
  match_count  int         default 1,
  primary key (engagement_a, device_a, engagement_b, device_b, basis),
  key idx_xref_b (engagement_b, device_b)
) $DB_COLLATE;"
