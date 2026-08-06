-- Deterministic seed data for the enrichment and burst passes.
--
-- SSIDs are written as lower(hex('...')) rather than pre-computed hex literals
-- so the intent of each row stays readable. That matches the pipeline
-- convention: ssid_hex is always lowercase hex of the raw SSID bytes.

-- ---------------------------------------------------------------------------
-- Enrichment fixtures
--
-- Spaced 200s apart, comfortably beyond SEQGRAPH_ALPHA. These represent
-- unrelated devices, so they must not chain together in the sequence graph.
-- When they were all stamped within microseconds of each other with sequential
-- seq numbers, the graph merged all 19 into a single device -- correct
-- behavior on incoherent input, and a good illustration of the algorithm's
-- real false-merge mode in dense environments.
-- ---------------------------------------------------------------------------

-- categorize(): keyword hits across a few different category buckets.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('Starbucks WiFi')), '02:00:00:00:00:01', '1700010000.000000', '-50', 2437, 1, '0x03fbfa00'),
  (lower(hex('Hilton Garden Inn')), '02:00:00:00:00:02', '1700010200.000000', '-55', 2437, 2, '0x03fbfa00'),
  (lower(hex('AndroidAP1234')), '02:00:00:00:00:03', '1700010400.000000', '-60', 2437, 3, '0x03fbfa00'),
  (lower(hex('Tesla Model 3')), '02:00:00:00:00:04', '1700010600.000000', '-65', 2437, 4, '0x03fbfa00');

-- check_fqdn(): must reach OTHER_FQDN. Currently never matches because $ssid is
-- computed before the read loop, so this row is the regression test for it.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('guest.abb')), '02:00:00:00:00:05', '1700010800.000000', '-70', 2437, 5, '0x03fbfa00');

-- check_name(): 'Adam' is in lists/names.txt.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('Adam''s iPhone')), '02:00:00:00:00:06', '1700011000.000000', '-45', 2437, 6, '0x03fbfa00');

-- check_airport(): 'AMS' is in lists/airports.txt.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('AMS Airport Free')), '02:00:00:00:00:07', '1700011200.000000', '-72', 2437, 7, '0x03fbfa00');

-- check_common(): 'xfinitywifi' is the top entry in lists/ssid.csv (21.8M
-- sightings). 'Yellowmonkey' is also in the list but with only 399, and
-- '010101' with 250. All three are therefore is_common=1, which is exactly the
-- point the rarity test makes: the binary flag cannot tell them apart, while
-- rarity puts them ~11 apart on a log scale.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('xfinitywifi')),  '02:00:00:00:00:08', '1700011400.000000', '-80', 2437, 8, '0x03fbfa00'),
  (lower(hex('Yellowmonkey')), '02:00:00:00:00:10', '1700011600.000000', '-81', 2437, 17, '0x03fbfa00'),
  (lower(hex('010101')),       '02:00:00:00:00:11', '1700011800.000000', '-82', 2437, 18, '0x03fbfa00');

-- summarize_location() / check_oneloc(): one row per canned WiGLE fixture in
-- test/fixtures/locs/.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('OneCity')), '02:00:00:00:00:09', '1700012000.000000', '-52', 2437, 9, '0x03fbfa00'),
  (lower(hex('ManyCities')), '02:00:00:00:00:0a', '1700012200.000000', '-53', 2437, 10, '0x03fbfa00'),
  (lower(hex('ManyCountries')), '02:00:00:00:00:0b', '1700012400.000000', '-54', 2437, 11, '0x03fbfa00'),
  (lower(hex('NoResults')), '02:00:00:00:00:0c', '1700012600.000000', '-56', 2437, 12, '0x03fbfa00');

-- check_anomalies(): hex-anomalous SSIDs (embedded nulls / 0xff runs).
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  ('000000000000', '02:00:00:00:00:0d', '1700012800.000000', '-90', 2437, 13, '0x03fbfa00'),
  ('fffffffffff0', '02:00:00:00:00:0e', '1700013000.000000', '-91', 2437, 14, '0x03fbfa00');

-- mac2vendor(): 00:1a:11 is Google in lists/oui.csv, and this SSID is probed by
-- exactly one MAC, which is the condition mac2vendor selects on.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('SingleMacNet')), '00:1a:11:00:00:01', '1700013200.000000', '-58', 2437, 15, '0x03fbfa00');

-- check_language(): a Cyrillic SSID (UTF-8 'Привет' starts d0 9f).
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex(_utf8mb4'Привет')), '02:00:00:00:00:0f', '1700013400.000000', '-61', 2437, 16, '0x03fbfa00');

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

-- Burst by seq + rssi: distinct MACs (randomized), sequence numbers within the
-- +60 window, RSSI within +/-2. Exercises ssid2bursts-seq, which never ran
-- before `seq!=null` was fixed, and the rssi varchar comparison.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('SeqBurstOne')),   '62:00:00:00:00:01', '1700000300.100000', '-60', 2437, 500, '0x03fbfa00'),
  (lower(hex('SeqBurstTwo')),   '66:00:00:00:00:02', '1700000300.200000', '-61', 2437, 510, '0x03fbfa00'),
  (lower(hex('SeqBurstThree')), '6a:00:00:00:00:03', '1700000300.300000', '-59', 2437, 520, '0x03fbfa00');

-- Burst by vht: distinct MACs sharing one VHT capability value and RSSI band.
-- The sequence numbers are deliberately more than 60 apart so the seq pass
-- cannot claim these rows first -- it would mark them is_processed=100 and the
-- vht pass (which selects is_processed=2) would never see them.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('VhtBurstOne')), '72:00:00:00:00:01', '1700000400.100000', '-70', 2437, 900, '0xdeadbeef'),
  (lower(hex('VhtBurstTwo')), '76:00:00:00:00:02', '1700000400.200000', '-71', 2437, 1500, '0xdeadbeef');

-- A wildcard/broadcast probe, stored with the <MISSING> sentinel exactly as
-- tshark reports it. Downstream queries filter on this literal string, so the
-- ingest fix must preserve it.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  ('<MISSING>', '02:00:00:00:00:ff', '1700013600.000000', '-88', 2437, 99, '0x03fbfa00');

-- ---------------------------------------------------------------------------
-- Sequence-graph fixtures (seqgraph_functions.sh)
-- ---------------------------------------------------------------------------

-- One device across three MAC rotations. Three bursts 50s apart, each under a
-- different randomized address, with the sequence counter running continuously
-- through all of them. The graph must join all eight frames into ONE device_id
-- spanning three MACs -- the old ssid2bursts-seq could never do this, because
-- its window was a single second.
--
-- The addresses are locally administered (second hex digit 2, 6, a) as a real
-- randomizing device's would be. That matters: seqgraph_validate treats
-- globally-unique MACs as ground truth, so using them here would make this
-- fixture look like three separate real devices wrongly merged.
-- All eight frames carry an identical IE signature, as one physical device
-- must: that is what lets the confidence check certify the merge as genuine.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht, ht, extcap, vendor_oui, ie_order) values
  (lower(hex('RoamHome')),  '12:00:00:00:00:01', '1700001000.000000', '-55', 2437, 1000, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  (lower(hex('RoamCafe')),  '12:00:00:00:00:01', '1700001000.100000', '-55', 2437, 1001, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  (lower(hex('RoamWork')),  '12:00:00:00:00:01', '1700001000.200000', '-55', 2437, 1002, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  -- MAC rotation #1, 50s later, sequence continues
  (lower(hex('RoamHome')),  '36:00:00:00:00:02', '1700001050.000000', '-56', 2437, 1060, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  (lower(hex('RoamCafe')),  '36:00:00:00:00:02', '1700001050.100000', '-56', 2437, 1061, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  (lower(hex('RoamWork')),  '36:00:00:00:00:02', '1700001050.200000', '-56', 2437, 1062, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  -- MAC rotation #2, another 50s on
  (lower(hex('RoamHome')),  '5a:00:00:00:00:03', '1700001100.000000', '-57', 2437, 1120, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221'),
  (lower(hex('RoamCafe')),  '5a:00:00:00:00:03', '1700001100.100000', '-57', 2437, 1121, '0x03fbfa00', '0x09ef', '0x04,0x00', '6130', '0,1,45,127,191,221');

-- A second, unrelated device. Far enough away in time (900s > alpha) that it
-- must NOT be merged into the chain above, despite plausible sequence numbers.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('OtherPhone')), '0e:00:00:00:00:01', '1700002000.000000', '-60', 2437, 1200, '0x03fbfa00'),
  (lower(hex('OtherPhone')), '0e:00:00:00:00:01', '1700002000.100000', '-60', 2437, 1201, '0x03fbfa00');

-- Two DIFFERENT physical devices, both with globally-unique (non-randomized)
-- MACs, interleaved in time with consecutive sequence numbers. This is the
-- algorithm's real-world false-merge mode: nothing in the timing or sequence
-- data distinguishes them, so an ungated graph chains all four frames into one
-- device. Because both MACs are globally unique, seqgraph_validate can prove
-- the merge is wrong without any external ground truth.
--
-- Their IE fingerprints differ, which is physically necessary for two different
-- devices, so SEQGRAPH_GATE_IE=1 blocks the bad edge and keeps them apart.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht, ht, extcap, vendor_oui, ie_order) values
  (lower(hex('GroundTruthA')), '00:11:22:00:00:01', '1700005000.000000', '-50', 2437, 100, '0x1', '0x09ef', '0x04', '6130',    '0,1,45,127,221'),
  (lower(hex('GroundTruthB')), '00:33:44:00:00:01', '1700005000.050000', '-50', 2437, 102, '0x2', '0x1122', '0xff', '5271450', '0,1,45,127,191,221'),
  (lower(hex('GroundTruthA')), '00:11:22:00:00:01', '1700005000.100000', '-50', 2437, 101, '0x1', '0x09ef', '0x04', '6130',    '0,1,45,127,221'),
  (lower(hex('GroundTruthB')), '00:33:44:00:00:01', '1700005000.150000', '-50', 2437, 103, '0x2', '0x1122', '0xff', '5271450', '0,1,45,127,191,221');

-- Sequence counter wrapping past its 12-bit maximum mid-chain: 4094 -> 2 is a
-- forward distance of 4, not a backward jump of 4092.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('WrapNet')), '82:00:00:00:00:01', '1700003000.000000', '-65', 2437, 4090, '0x03fbfa00'),
  (lower(hex('WrapNet')), '82:00:00:00:00:01', '1700003000.100000', '-65', 2437, 4094, '0x03fbfa00'),
  (lower(hex('WrapNet')), '86:00:00:00:00:02', '1700003000.200000', '-65', 2437,    2, '0x03fbfa00');

-- ---------------------------------------------------------------------------
-- Directed probe requests (geolocate_functions.sh)
--
-- Most probes are undirected and carry ff:ff:ff:ff:ff:ff as the destination.
-- A directed probe -- for a hidden network, or an AP the device already knows
-- -- addresses the AP itself, so wlan_da is that AP's BSSID. That is the only
-- route by which a BSSID ever reaches this pipeline, and BSSIDs are what every
-- positioning service except WiGLE is keyed on.
-- ---------------------------------------------------------------------------
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht, wlan_da) values
  (lower(hex('OneCity')),   '92:00:00:00:00:01', '1700006000.000000', '-50', 2437, 700, '0x1', 'de:ad:be:ef:00:01'),
  (lower(hex('OneCity')),   '92:00:00:00:00:01', '1700006000.100000', '-50', 2437, 701, '0x1', 'de:ad:be:ef:00:01'),
  (lower(hex('ManyCities')),'96:00:00:00:00:02', '1700006100.000000', '-55', 2437, 800, '0x1', 'de:ad:be:ef:00:02'),
  (lower(hex('HiddenNet')), '9a:00:00:00:00:03', '1700006200.000000', '-60', 2437, 900, '0x1', 'ff:ff:ff:ff:ff:ff');

-- ---------------------------------------------------------------------------
-- Recategorization fixtures (recategorize_functions.sh)
--
-- Names that categorize() leaves as OTHER_UNKNOWN because no keyword matches,
-- but which are still placeable from their shape or from the operator brand
-- list in lists/cpe_isp.txt.
-- ---------------------------------------------------------------------------
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  -- operator brands: single national market
  (lower(hex('Bbox-7A21')),        'a2:00:00:00:01:01', '1700020000.000000', '-50', 2437, 10, '0x1'),
  (lower(hex('BTHub6-XKQP')),      'a2:00:00:00:01:02', '1700020200.000000', '-51', 2437, 11, '0x1'),
  (lower(hex('MEO_WiFi_2E')),      'a2:00:00:00:01:03', '1700020400.000000', '-52', 2437, 12, '0x1'),
  -- operator brand spanning several markets
  (lower(hex('MOVISTAR_A4F2')),    'a2:00:00:00:01:04', '1700020600.000000', '-53', 2437, 13, '0x1'),
  -- hardware vendor: must NOT be given a country
  (lower(hex('NETGEAR58-Guest')),  'a2:00:00:00:01:05', '1700020800.000000', '-54', 2437, 14, '0x1'),
  -- shape only: trailing MAC fragment, no recognizable brand
  (lower(hex('Brightwood-3F17')),    'a2:00:00:00:01:06', '1700021000.000000', '-55', 2437, 15, '0x1'),
  -- shape only: band suffix
  (lower(hex('Jacaranda-5G')),     'a2:00:00:00:01:07', '1700021200.000000', '-56', 2437, 16, '0x1'),
  -- a phone model that merely contains 5G mid-name must NOT be caught
  (lower(hex('Galaxy A53 5G 0F92')),'a2:00:00:00:01:08','1700021400.000000', '-57', 2437, 17, '0x1'),
  -- guest access, non-English
  (lower(hex('La Maison-Invitados')),'a2:00:00:00:01:09','1700021600.000000','-58', 2437, 18, '0x1'),
  -- consumer appliance
  (lower(hex('LEDnet00040486FF')), 'a2:00:00:00:01:0a', '1700021800.000000', '-59', 2437, 19, '0x1'),
  -- digits only
  (lower(hex('4085551234')),       'a2:00:00:00:01:0b', '1700022000.000000', '-60', 2437, 20, '0x1'),
  -- genuinely unplaceable: must stay OTHER_UNKNOWN
  (lower(hex('Quebrador San Miguel')),'a2:00:00:00:01:0c','1700022200.000000','-61',2437, 21, '0x1');

-- Mined-pattern fixtures: workplace, residence and generic network markers.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('Ukrtelecom_4471')), 'a6:00:00:00:02:01', '1700030000.000000', '-50', 2437, 30, '0x1'),
  (lower(hex('Torres Staff')),    'a6:00:00:00:02:02', '1700030200.000000', '-51', 2437, 31, '0x1'),
  (lower(hex('Ruiz Family')),     'a6:00:00:00:02:03', '1700030400.000000', '-52', 2437, 32, '0x1'),
  (lower(hex('Alvarez_network')), 'a6:00:00:00:02:04', '1700030600.000000', '-53', 2437, 33, '0x1'),
  (lower(hex('Redwood Lodge')),   'a6:00:00:00:02:05', '1700030800.000000', '-54', 2437, 34, '0x1');

-- Latin-script language markers. check_language() detects languages by script
-- and is blind to all of these; language_functions.sh reads vocabulary instead.
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht) values
  (lower(hex('Netzwerk Mueller')),  'aa:00:00:00:03:01', '1700040000.000000', '-50', 2437, 40, '0x1'),
  (lower(hex('Huis van Dijk')),     'aa:00:00:00:03:02', '1700040200.000000', '-51', 2437, 41, '0x1'),
  (lower(hex('Cocina Abajo')),      'aa:00:00:00:03:03', '1700040400.000000', '-52', 2437, 42, '0x1'),
  (lower(hex('Maison Dupont')),     'aa:00:00:00:03:04', '1700040600.000000', '-53', 2437, 43, '0x1'),
  (lower(hex('Casa Bonita')),       'aa:00:00:00:03:05', '1700040800.000000', '-54', 2437, 44, '0x1'),
  (lower(hex('Redwood Cabin')),     'aa:00:00:00:03:06', '1700041000.000000', '-55', 2437, 45, '0x1'),
  (lower(hex('Netzwerk Cucina')),   'aa:00:00:00:03:07', '1700041200.000000', '-56', 2437, 46, '0x1');

-- ---------------------------------------------------------------------------
-- A device with a full profile, for the in-range operator display.
--
-- One person's preferred network list: household, employer, a geolocated
-- network, an airport, a hotel, an eatery and a home ISP -- probed as one
-- burst so display_inrange sees them together.
-- ---------------------------------------------------------------------------
insert into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht, ht, extcap, vendor_oui, ie_order) values
  (lower(hex('Familia Restrepo')), 'be:00:00:00:04:01', '1700050000.000000', '-48', 2437, 4000, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('Vertex Labs Staff')),'be:00:00:00:04:01', '1700050000.100000', '-48', 2437, 4001, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('OneCity')),          'be:00:00:00:04:01', '1700050000.200000', '-48', 2437, 4002, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('AMS Airport Free')), 'be:00:00:00:04:01', '1700050000.300000', '-48', 2437, 4003, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('Hilton Garden Inn')),'be:00:00:00:04:01', '1700050000.400000', '-48', 2437, 4004, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('Starbucks WiFi')),   'be:00:00:00:04:01', '1700050000.500000', '-48', 2437, 4005, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('Bbox-7A21')),        'be:00:00:00:04:01', '1700050000.600000', '-48', 2437, 4006, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221'),
  (lower(hex('Cocina Abajo')),     'be:00:00:00:04:01', '1700050000.700000', '-48', 2437, 4007, '0x1', '0x09ef', '0x04', '6130', '0,1,45,127,221');
