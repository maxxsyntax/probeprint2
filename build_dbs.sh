#!/usr/bin/bash

mysql -e "create database if not exists probeprint;"

mysql probeprint -e "create table if not exists ssid(ssid_hex varchar(200), wlan_sa varchar(17), time varchar(22) primary key, rssi varchar(12), freq integer, seq integer, vht varchar(20), is_processed integer default 0, vendor text default null, tag text default null);"


mysql probeprint -e "create table if not exists ssid_intel(ssid_hex varchar(255) primary key,  location varchar(64), category varchar(32), is_name varchar(20),is_airport varchar(255), is_common integer default null, is_oneloc integer, score integer default null);"

mysql probeprint -e "create table if not exists bursts(ssids text, time varchar(22) primary key, burst_size integer, burst_duration varchar(22) default 0, related_burst integer default 0, is_uniq integer default null, bmethod varchar(20) default null);"

# The distributed client/ nodes connect as 'pi' to the central database.
# These were previously bare SQL statements outside any mysql invocation, so
# bash tried to execute `create` as a command and the user was never created.
mysql -e "create user if not exists 'pi'@'%';"
mysql -e "grant all privileges on probeprint.* to 'pi'@'%';"
