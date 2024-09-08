#!/bin/bash

mysql probeprint "create table ssid(ssid_hex varchar(200), wlan_sa varchar(17), time varchar(22) primary key, rssi varchar(12), freq integer, seq integer, vht varchar(20), is_processed integer default 0, vendor text default null, tag text default null);"


mysql probeprint "create table ssid_intel(ssid_hex varchar(255) primary key, score integer, location varchar(64), category varchar(32), is_name varchar(20),is_airport varchar(255), is_common integer default null, is_oneloc integer, is_vht integer);"

mysql probeprint "create table bursts(ssids text, time varchar(22) primary key, burst_size integer, burst_duration varchar(22) default 0, related_burst integer default 0, is_uniq integer default null, bmethod varchar(20) default null);


###Print should be more accurate and have all information
sqlite3 prints.db "create table prints ( friendly_name text, score integer default 0, primary_burst text primary key, possible_bt text, is_vip integer default 0, common_regions text, cat_notes1 text, cat_notes2 text, ssid_cats text, seenb4_date text, lowest_rssi text);"



# PRAGMA journal_mode=WAL;



