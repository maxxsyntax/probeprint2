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

# Device identity assigned by the sequence-number graph (seqgraph_functions.sh),
# which chains probe requests across MAC randomisation.
mysql probeprint -e "alter table ssid add column if not exists device_id varchar(32) default null;"
mysql probeprint -e "create index if not exists idx_ssid_device_id on ssid (device_id);"
mysql probeprint -e "create index if not exists idx_ssid_seq_time on ssid (seq, time);"

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
