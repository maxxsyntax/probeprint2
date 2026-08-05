-- Deterministic seed data for the enrichment and burst passes.
--
-- SSIDs are written as lower(hex('...')) rather than pre-computed hex literals
-- so the intent of each row stays readable. That matches the pipeline
-- convention: ssid_hex is always lowercase hex of the raw SSID bytes.

-- ---------------------------------------------------------------------------
-- Enrichment fixtures
-- ---------------------------------------------------------------------------

-- categorize(): keyword hits across a few different category buckets.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('Starbucks WiFi')), '02:00:00:00:00:01', '1700000100.000001', '-50', 2437, 1, '0x03fbfa00'),
  (lower(hex('Hilton Garden Inn')), '02:00:00:00:00:02', '1700000100.000002', '-55', 2437, 2, '0x03fbfa00'),
  (lower(hex('AndroidAP1234')), '02:00:00:00:00:03', '1700000100.000003', '-60', 2437, 3, '0x03fbfa00'),
  (lower(hex('Tesla Model 3')), '02:00:00:00:00:04', '1700000100.000004', '-65', 2437, 4, '0x03fbfa00');

-- check_fqdn(): must reach OTHER_FQDN. Currently never matches because $ssid is
-- computed before the read loop, so this row is the regression test for it.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('guest.abb')), '02:00:00:00:00:05', '1700000100.000005', '-70', 2437, 5, '0x03fbfa00');

-- check_name(): 'Adam' is in lists/names.txt.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('Adam''s iPhone')), '02:00:00:00:00:06', '1700000100.000006', '-45', 2437, 6, '0x03fbfa00');

-- check_airport(): 'AMS' is in lists/airports.txt.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('AMS Airport Free')), '02:00:00:00:00:07', '1700000100.000007', '-72', 2437, 7, '0x03fbfa00');

-- check_common(): 'xfinitywifi' is the top entry in lists/ssid.csv.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('xfinitywifi')), '02:00:00:00:00:08', '1700000100.000008', '-80', 2437, 8, '0x03fbfa00');

-- summarize_location() / check_oneloc(): one row per canned WiGLE fixture in
-- test/fixtures/locs/.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('OneCity')), '02:00:00:00:00:09', '1700000100.000009', '-52', 2437, 9, '0x03fbfa00'),
  (lower(hex('ManyCities')), '02:00:00:00:00:0a', '1700000100.000010', '-53', 2437, 10, '0x03fbfa00'),
  (lower(hex('ManyCountries')), '02:00:00:00:00:0b', '1700000100.000011', '-54', 2437, 11, '0x03fbfa00'),
  (lower(hex('NoResults')), '02:00:00:00:00:0c', '1700000100.000012', '-56', 2437, 12, '0x03fbfa00');

-- check_anomalies(): hex-anomalous SSIDs (embedded nulls / 0xff runs).
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  ('000000000000', '02:00:00:00:00:0d', '1700000100.000013', '-90', 2437, 13, '0x03fbfa00'),
  ('fffffffffff0', '02:00:00:00:00:0e', '1700000100.000014', '-91', 2437, 14, '0x03fbfa00');

-- mac2vendor(): 00:1a:11 is Google in lists/oui.csv, and this SSID is probed by
-- exactly one MAC, which is the condition mac2vendor selects on.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('SingleMacNet')), '00:1a:11:00:00:01', '1700000100.000015', '-58', 2437, 15, '0x03fbfa00');

-- check_language(): a Cyrillic SSID (UTF-8 'Привет' starts d0 9f).
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex(_utf8mb4'Привет')), '02:00:00:00:00:0f', '1700000100.000016', '-61', 2437, 16, '0x03fbfa00');

-- ---------------------------------------------------------------------------
-- Burst fixtures
-- ---------------------------------------------------------------------------

-- Burst by wlan_sa: 4 probes from one MAC inside a 1-second window.
-- Exercises bursts_functions.sh:ssid_2bursts-wlan_sa, which never ran before
-- the missing `and` was fixed.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('BurstAlpha')),   '0a:00:00:00:00:01', '1700000200.100000', '-50', 2437, 200, '0x03fbfa00'),
  (lower(hex('BurstBravo')),   '0a:00:00:00:00:01', '1700000200.200000', '-50', 2437, 201, '0x03fbfa00'),
  (lower(hex('BurstCharlie')), '0a:00:00:00:00:01', '1700000200.300000', '-51', 2437, 202, '0x03fbfa00'),
  (lower(hex('BurstDelta')),   '0a:00:00:00:00:01', '1700000200.400000', '-51', 2437, 203, '0x03fbfa00');

-- Burst by seq + rssi: distinct MACs (randomised), sequence numbers within the
-- +60 window, RSSI within +/-2. Exercises ssid2bursts-seq, which never ran
-- before `seq!=null` was fixed, and the rssi varchar comparison.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('SeqBurstOne')),   '0b:00:00:00:00:01', '1700000300.100000', '-60', 2437, 500, '0x03fbfa00'),
  (lower(hex('SeqBurstTwo')),   '0b:00:00:00:00:02', '1700000300.200000', '-61', 2437, 510, '0x03fbfa00'),
  (lower(hex('SeqBurstThree')), '0b:00:00:00:00:03', '1700000300.300000', '-59', 2437, 520, '0x03fbfa00');

-- Burst by vht: distinct MACs sharing one VHT capability value and RSSI band.
-- The sequence numbers are deliberately more than 60 apart so the seq pass
-- cannot claim these rows first -- it would mark them is_processed=100 and the
-- vht pass (which selects is_processed=2) would never see them.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('VhtBurstOne')), '0c:00:00:00:00:01', '1700000400.100000', '-70', 2437, 900, '0xdeadbeef'),
  (lower(hex('VhtBurstTwo')), '0c:00:00:00:00:02', '1700000400.200000', '-71', 2437, 1500, '0xdeadbeef');

-- A wildcard/broadcast probe, stored with the <MISSING> sentinel exactly as
-- tshark reports it. Downstream queries filter on this literal string, so the
-- ingest fix must preserve it.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  ('<MISSING>', '02:00:00:00:00:ff', '1700000100.000099', '-88', 2437, 99, '0x03fbfa00');
