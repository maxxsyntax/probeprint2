#!/bin/bash
# Per-engagement working tables, folding into the master archive, and
# cross-engagement correlation without merging device ids.
#
# The working ssid/devices/device_ssid hold one engagement at a time (so
# seqgraph stays bounded); fold_engagement.sh appends them to the *_master
# tables namespaced by engagement, then empties the working set;
# correlate_engagements.sh links devices across engagements in device_xref.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db
mysql probeprint -e "delete from ssid; delete from devices; delete from device_ssid;
                     delete from ssid_master; delete from devices_master;
                     delete from device_ssid_master; delete from device_xref;
                     delete from ssid_intel;"

# Shared enrichment (one master ssid_intel). Three discriminative SSIDs plus a
# common one that must never contribute to a link.
S_NAME="$(hexof SmithHouse)"; S_CAT="$(hexof AcmeCorp)"; S_LOC="$(hexof PlazaWifi)"
S_COMMON="$(hexof xfinitywifi)"
mysql probeprint <<SQL
insert into ssid_intel (ssid_hex, is_name, is_common) values ('$S_NAME','Smith',0);
insert into ssid_intel (ssid_hex, category, is_common) values ('$S_CAT','CORP',0);
insert into ssid_intel (ssid_hex, is_oneloc, lat, lon, is_common) values ('$S_LOC',1,40.123,-74.456,0);
insert into ssid_intel (ssid_hex, category, is_common) values ('$S_COMMON','OTHER_UNKNOWN',1);
SQL

# build_engagement <name> <static_mac_for_dev1>
# Populates the WORKING tables with a small engagement: dev 1 keyed by a static
# MAC, dev 2 with the three shared attributes, dev 3 sharing only one attribute.
build_engagement () {
	local eng=$1 mac=$2
	mysql probeprint <<SQL
insert into ssid (ssid_hex, wlan_sa, time, tag, device_id) values
  ('$S_COMMON','$mac',      '${eng}.1', '$eng', 1),
  ('$S_COMMON','$mac',      '${eng}.2', '$eng', 1),
  ('$S_NAME',  '0a:11:22:33:44:61','${eng}.3','$eng',2),
  ('$S_CAT',   '0a:11:22:33:44:62','${eng}.4','$eng',2),
  ('$S_LOC',   '0a:11:22:33:44:63','${eng}.5','$eng',2),
  ('$S_NAME',  '0a:11:22:33:44:71','${eng}.6','$eng',3);

insert into devices (id, device_key, vendor, confidence) values
  (1,'${eng}key0001','Intel','high'),
  (2,'${eng}key0002','Apple','high'),
  (3,'${eng}key0003','Samsung','high');

insert into device_ssid (device_id, ssid_hex) values
  (1,'$S_COMMON'),
  (2,'$S_NAME'), (2,'$S_CAT'), (2,'$S_LOC'),
  (3,'$S_NAME');
SQL
}

# --- engagement alpha, fold ------------------------------------------------
# dev 1's MAC is burned-in (00:...): second hex digit 0, not in {2,6,a,e}.
build_engagement alpha 00:11:22:33:44:55
./analysis-scripts/fold_engagement.sh alpha >/tmp/fold_a.log 2>&1

assert_eq "fold moves frames into the master under the engagement" "6" \
	"$(sq1 "select count(*) from ssid_master where tag='alpha';")"
assert_eq "fold moves devices into the master, namespaced" "3" \
	"$(sq1 "select count(*) from devices_master where engagement='alpha';")"
assert_eq "and the preferred network lists" "5" \
	"$(sq1 "select count(*) from device_ssid_master where engagement='alpha';")"
assert_eq "the working ssid table is emptied for the next engagement" "0" \
	"$(sq1 "select count(*) from ssid;")"
assert_eq "and working devices too" "0" \
	"$(sq1 "select count(*) from devices;")"

# --- engagement beta, fold -------------------------------------------------
# Same burned-in MAC on dev 1 (a returning device) and the same three shared
# attributes on dev 2 -- but device ids restart at 1, testing the namespacing.
build_engagement beta 00:11:22:33:44:55
./analysis-scripts/fold_engagement.sh beta >/tmp/fold_b.log 2>&1

assert_eq "two engagements coexist in the master" "2" \
	"$(sq1 "select count(distinct engagement) from devices_master;")"
assert_eq "the reused device id 1 exists under both engagements" "2" \
	"$(sq1 "select count(*) from devices_master where id=1 and engagement in ('alpha','beta');")"

# --- fold is idempotent ----------------------------------------------------
build_engagement beta 00:11:22:33:44:55
./analysis-scripts/fold_engagement.sh beta >/tmp/fold_b2.log 2>&1
assert_eq "re-folding an engagement replaces rather than duplicates" "6" \
	"$(sq1 "select count(*) from ssid_master where tag='beta';")"

# --- correlate across engagements ------------------------------------------
./analysis-scripts/correlate_engagements.sh >/tmp/xref.log 2>&1

assert_eq "a shared burned-in MAC links the two devices" "1" \
	"$(sq1 "select count(*) from device_xref where basis='static_mac'
	         and engagement_a='alpha' and device_a=1
	         and engagement_b='beta' and device_b=1;")"
assert_eq "three shared attributes link dev 2 across engagements" "1" \
	"$(sq1 "select count(*) from device_xref where basis='attributes'
	         and engagement_a='alpha' and device_a=2
	         and engagement_b='beta' and device_b=2;")"
assert_eq "and the attribute link counts at least three" "1" \
	"$(sq1 "select match_count >= 3 from device_xref where basis='attributes'
	         and device_a=2 and device_b=2 limit 1;")"

# dev 3 shares only the one name attribute -> below the threshold, no link.
assert_eq "one shared attribute is not enough to link" "0" \
	"$(sq1 "select count(*) from device_xref where device_a=3 and device_b=3;")"

# a common SSID (xfinitywifi) shared by dev 1 in both must NOT create an
# attribute link -- only the hardware MAC did.
assert_eq "a shared common SSID never links on attributes" "0" \
	"$(sq1 "select count(*) from device_xref where basis='attributes' and device_a=1 and device_b=1;")"

finish
