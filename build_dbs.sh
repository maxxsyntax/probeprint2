#!/usr/bin/bash


#mysql create database probeprint

mysql probeprint -e "create table ssid(ssid_hex varchar(200), wlan_sa varchar(17), time varchar(22) primary key, rssi varchar(12), freq integer, seq integer, vht varchar(20), is_processed integer default 0, vendor text default null, tag text default null);"


mysql probeprint -e "create table ssid_intel(ssid_hex varchar(255) primary key,  location varchar(64), category varchar(32), is_name varchar(20),is_airport varchar(255), is_common integer default null, is_oneloc integer);"

mysql probeprint -e "create table bursts(ssids text, time varchar(22) primary key, burst_size integer, burst_duration varchar(22) default 0, related_burst integer default 0, is_uniq integer default null, bmethod varchar(20) default null);"




create user 'pi'@'%';
grant all privileges on probeprint.* to 'pi'@'%' ;
