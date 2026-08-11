#!/bin/bash
# Offline location lookup from local WiGLE exports (WigleWifi_*.csv[.gz]).
#
# The offline peer of the locs/ cache path (case 12): same resolution rules --
# count the distinct APs carrying the exact name, fix only when they name one
# place or cluster -- sourced from the bulk wardrive exports instead of the API,
# and recorded as geo_source='wigle_csv'. Entirely offline; makes no network
# call, so it is safe in CI.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

reset_db

CSVDIR=$(mktemp -d)
trap 'rm -rf "$CSVDIR"' EXIT

# --- a synthetic export, covering each resolution outcome -----------------
{
	printf 'WigleWifi-1.6,appRelease=2.0,model=Test,release=1,device=t,display=t,board=t,brand=t\n'
	printf 'MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type\n'
	# one AP -> definitive
	printf 'aa:aa:aa:00:00:01,UniqueHome,[WPA2],2021-01-01 00:00:00,6,2437,-50,40.1,-74.1,100,5,,,WIFI\n'
	# two APs within ~0.005 deg -> a centroid fix
	printf 'bb:bb:bb:00:00:02,ClusterCorp,[WPA2],2021-01-01 00:00:00,6,2437,-50,41.0000,-75.0000,100,5,,,WIFI\n'
	printf 'bb:bb:bb:00:00:03,ClusterCorp,[WPA2],2021-01-01 00:00:00,6,2437,-50,41.0050,-75.0050,100,5,,,WIFI\n'
	# two APs far apart -> no fix, but the ambiguity is recorded
	printf 'bb:bb:bb:00:00:04,SpreadNet,[WPA2],2021-01-01 00:00:00,6,2437,-50,10.0,20.0,100,5,,,WIFI\n'
	printf 'bb:bb:bb:00:00:05,SpreadNet,[WPA2],2021-01-01 00:00:00,6,2437,-50,12.0,22.0,100,5,,,WIFI\n'
	# case sensitivity: exact CaseNet in Paris, a lowercase namesake in Sydney
	printf 'cc:cc:cc:00:00:0a,CaseNet,[WPA2],2021-01-01 00:00:00,6,2437,-50,48.5,2.2,100,5,,,WIFI\n'
	printf 'cc:cc:cc:00:00:0b,casenet,[WPA2],2021-01-01 00:00:00,6,2437,-50,-33.8,151.2,100,5,,,WIFI\n'
	# an SSID containing a comma -- must not shift the coordinate columns
	printf 'dd:dd:dd:00:00:06,Bob, Alice Net,[WPA2],2021-01-01 00:00:00,6,2437,-50,33.0,-96.0,100,5,,,WIFI\n'
	# a BLE row that must be ignored entirely
	printf 'ee:ee:ee:00:00:09,IgnoreMe,,2021-01-01 00:00:00,0,0,-70,1.0,2.0,,,,,BLE\n'
	# a hardware BSSID, two close observations -> located in bssid_geo
	printf 'cc:cc:cc:00:00:07,SomeAP,[WPA2],2021-01-01 00:00:00,6,2437,-50,51.5000,-0.1200,100,5,,,WIFI\n'
	printf 'cc:cc:cc:00:00:07,SomeAP,[WPA2],2021-01-01 00:00:01,6,2437,-52,51.5010,-0.1210,100,5,,,WIFI\n'
	# a row whose SSID is already resolved by the API path -> must not be clobbered
	printf 'ff:ff:ff:00:00:08,ApiOwned,[WPA2],2021-01-01 00:00:00,6,2437,-50,1.0,1.0,100,5,,,WIFI\n'
} > "$CSVDIR/WigleWifi_20260101000000.csv"

# a gzipped export with CRLF line endings, exercising both the .gz and the
# carriage-return handling in one file
{
	printf 'WigleWifi-1.6,appRelease=2.0,model=Test\r\n'
	printf 'MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type\r\n'
	printf 'ab:ab:ab:00:00:20,GzOnlyNet,[WPA2],2021-01-01 00:00:00,6,2437,-50,35.68,139.76,100,5,,,WIFI\r\n'
} | gzip -c > "$CSVDIR/WigleWifi_20260202000000.csv.gz"

# --- seed the rows the resolver will fill ---------------------------------
mysql probeprint -e "delete from ssid_intel; delete from bssid_geo;"
for s in UniqueHome ClusterCorp SpreadNet CaseNet GzOnlyNet; do
	mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values (lower(hex('$s')));"
done
# The comma SSID cannot go through the shell loop cleanly; hex it directly.
mysql probeprint -e "insert ignore into ssid_intel (ssid_hex) values ('$(hexof 'Bob, Alice Net')');"
# Already resolved by the online path: geo_match_count is set, so the
# incremental guard must leave it untouched.
mysql probeprint -e "insert into ssid_intel (ssid_hex, lat, lon, geo_source, geo_match_count)
   values (lower(hex('ApiOwned')), 9.9, 9.9, 'wigle', 1);"
# A directed-probe BSSID awaiting a location.
mysql probeprint -e "insert into bssid_geo (bssid, probe_count) values ('cc:cc:cc:00:00:07', 3);"

# --- run the offline resolver ---------------------------------------------
./analysis-scripts/geolocate.sh --csv "$CSVDIR" >/tmp/csv.log 2>&1

# --- definitive: one AP carries the name ----------------------------------
assert_eq "a single-AP SSID gets coordinates" "40.1,-74.1" \
	"$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('UniqueHome'));")"
assert_eq "and is sourced as wigle_csv, not wigle" "wigle_csv" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('UniqueHome'));")"
assert_eq "one physical AP means geo_match_count 1" "1" \
	"$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('UniqueHome'));")"

# --- clustered: several APs but within ~1km -------------------------------
assert_eq "two clustered APs still yield a fix" "wigle_csv" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('ClusterCorp'));")"
assert_eq "the fix is the centroid of the cluster" "41.0025" \
	"$(sq1 "select round(lat,4) from ssid_intel where ssid_hex=lower(hex('ClusterCorp'));")"
assert_eq "and it counts two distinct APs" "2" \
	"$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('ClusterCorp'));")"

# --- dispersed: several APs, too far apart to be one place ----------------
assert_eq "two far-apart APs get no coordinate" "NULL" \
	"$(sq1 "select ifnull(lat,'NULL') from ssid_intel where ssid_hex=lower(hex('SpreadNet'));")"
assert_eq "but the ambiguity is still recorded" "2" \
	"$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('SpreadNet'));")"

# --- case sensitivity is free: the hex join is exact-byte -----------------
assert_eq "exact-case SSID takes its own coordinates, not the namesake's" "48.5,2.2" \
	"$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('CaseNet'));")"
assert_eq "and counts only the exact-case AP" "1" \
	"$(sq1 "select geo_match_count from ssid_intel where ssid_hex=lower(hex('CaseNet'));")"

# --- an SSID containing a comma parses right-anchored ---------------------
assert_eq "an SSID containing a comma resolves" "wigle_csv" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex='$(hexof 'Bob, Alice Net')';")"
assert_eq "and its latitude is not a shifted column" "33" \
	"$(sq1 "select round(lat) from ssid_intel where ssid_hex='$(hexof 'Bob, Alice Net')';")"

# --- a gzipped, CRLF export is read ---------------------------------------
assert_eq "a gzipped CRLF export is read" "wigle_csv" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('GzOnlyNet'));")"
assert_eq "and resolves to its coordinates" "35.68,139.76" \
	"$(sq1 "select concat_ws(',',round(lat,2),round(lon,2)) from ssid_intel where ssid_hex=lower(hex('GzOnlyNet'));")"

# --- BSSIDs: the offline path's bonus, no other offline provider can ------
assert_eq "a directed-probe BSSID is located from the export" "wigle_csv" \
	"$(sq1 "select geo_source from bssid_geo where bssid='cc:cc:cc:00:00:07';")"
assert_eq "at the mean of its observations" "51.50" \
	"$(sq1 "select round(lat,2) from bssid_geo where bssid='cc:cc:cc:00:00:07';")"

# --- provenance: a more authoritative API fix is never overwritten --------
assert_eq "an API-owned fix survives the incremental CSV pass" "9.9,9.9" \
	"$(sq1 "select concat_ws(',',lat,lon) from ssid_intel where ssid_hex=lower(hex('ApiOwned'));")"
assert_eq "and keeps its original source" "wigle" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('ApiOwned'));")"

# --- recompute redoes CSV-owned rows but still spares the API fix ---------
./analysis-scripts/geolocate.sh --csv "$CSVDIR" --recompute >/tmp/csv2.log 2>&1
assert_eq "recompute leaves the API-owned fix intact" "wigle" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('ApiOwned'));")"
assert_eq "and re-resolves a CSV-owned row" "wigle_csv" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('UniqueHome'));")"

# --- --import loads a locatable export SSID never probed for --------------
# SomeAP appears only as a BSSID observation in the export; it is not in the
# seed and was never given an ssid_intel row. --import should load it, with its
# coordinates. A dispersed SSID must NOT be loaded (it has no single place).
assert_eq "before --import a wardrived-only SSID has no row" "0" \
	"$(sq1 "select count(*) from ssid_intel where ssid_hex=lower(hex('SomeAP'));")"
./analysis-scripts/geolocate.sh --csv "$CSVDIR" --import >/tmp/csv3.log 2>&1
assert_eq "--import loads the locatable export SSID" "wigle_csv" \
	"$(sq1 "select geo_source from ssid_intel where ssid_hex=lower(hex('SomeAP'));")"
assert_eq "with its coordinates" "51.50" \
	"$(sq1 "select round(lat,2) from ssid_intel where ssid_hex=lower(hex('SomeAP'));")"
assert_eq "but a dispersed export SSID is not loaded" "0" \
	"$(sq1 "select count(*) from ssid_intel where ssid_hex=lower(hex('SpreadNet')) and geo_source='wigle_csv';")"

finish
