#!/bin/bash
# Ingest: every tshark field must land in its own database column, including
# when a middle field (rssi, freq) is empty.
#
# This is the regression test for the original space-separated `arr=($line)`
# parser, which shifted every column left past an empty field.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

PCAP=/tmp/probes.pcap
python3 test/fixtures/make_pcap.py "$PCAP" 2>/dev/null

mysql probeprint -e "delete from ssid; delete from ssid_intel; delete from bursts;"

# Import through the real pcap path, which shares ingest_functions.sh with the
# live capture path.
./capture-scripts/pcap2db.sh "$PCAP" >/tmp/ingest.log 2>&1

# --- happy path -----------------------------------------------------------
row=$(sq1 "select concat_ws('/',wlan_sa,rssi,freq,seq,vht) from ssid where ssid_hex='$(hexof HomeNetwork)';")
assert_eq "all fields present land in the right columns" \
    "aa:bb:cc:dd:ee:01/-42/2437/100/0x80170032" "$row"

# --- the bug: empty rssi must NOT shift freq/seq/vht ----------------------
row=$(sq1 "select concat_ws('/',coalesce(rssi,'NULL'),freq,seq,vht) from ssid where ssid_hex='$(hexof NoSignalNet)';")
assert_eq "empty rssi does not shift freq/seq/vht" \
    "/2437/101/0x80170032" "$row"

# freq must be the real frequency, not the sequence number bleeding across.
assert_eq "freq is a real 2.4GHz channel, not a shifted seq" \
    "2437" "$(sq1 "select freq from ssid where ssid_hex='$(hexof NoSignalNet)';")"

# --- empty freq must not shift seq/vht ------------------------------------
row=$(sq1 "select concat_ws('/',rssi,coalesce(freq,'NULL'),seq,vht) from ssid where ssid_hex='$(hexof NoChannelNet)';")
assert_eq "empty freq does not shift seq/vht" \
    "-42/NULL/102/0x80170032" "$row"

# --- trailing empty field -------------------------------------------------
row=$(sq1 "select concat_ws('/',rssi,freq,seq,coalesce(vht,'')) from ssid where ssid_hex='$(hexof NoVhtNet)';")
assert_eq "missing vht leaves earlier columns intact" \
    "-42/2437/103/" "$row"

# --- <MISSING> sentinel preserved for wildcard probes ---------------------
# tshark reports a zero-length SSID as the literal string <MISSING>, and
# downstream queries filter on it, so it must survive ingest verbatim.
#
# This also pins the pcap2db.sh display-filter fix: its old
# `wlan.tag.length != 0` clause dropped every wildcard probe, because a
# Wireshark `!=` means "no occurrence equals" and a wildcard probe always
# carries a zero-length SSID IE.
assert_eq "broadcast probe stored with the <MISSING> sentinel" \
    "1" "$(sq1 "select count(*) from ssid where ssid_hex='<MISSING>';")"
assert_eq "broadcast probe keeps its own MAC" \
    "aa:bb:cc:dd:ee:05" "$(sq1 "select wlan_sa from ssid where ssid_hex='<MISSING>';")"

# --- SSIDs with awkward bytes survive round-trip --------------------------
assert_eq "SSID containing a double quote round-trips" \
    'He said "hi"' \
    "$(sq1 "select unhex(ssid_hex) from ssid where ssid_hex='$(hexof 'He said "hi"')';")"
assert_eq "SSID containing a space round-trips" \
    "My Home WiFi" \
    "$(sq1 "select unhex(ssid_hex) from ssid where ssid_hex='$(hexof 'My Home WiFi')';")"

# --- duplicate timestamps must not hang or error -------------------------
# `time` is the primary key, so two frames sharing a timestamp collide. Exactly
# one should survive, and the importer must not spin retrying (the old
# pcap2db.sh retried the identical failing insert forever).
assert_eq "duplicate timestamp keeps one row, no retry loop" \
    "1" "$(sq1 "select count(*) from ssid where time like '1700000020%';")"
assert_not_contains "importer did not enter a retry loop" \
    "retry" "$(cat /tmp/ingest.log)"

# --- no numeric column ever holds a timestamp ----------------------------
# The clearest signature of the shift bug: an epoch value landing in rssi.
assert_eq "no rssi value looks like an epoch timestamp" \
    "0" "$(sq1 "select count(*) from ssid where rssi regexp '^1[0-9]{9}';")"
assert_eq "no freq value is outside the plausible wifi range" \
    "0" "$(sq1 "select count(*) from ssid where freq is not null and (freq < 2000 or freq > 7200);")"

# --- tag written by pcap2db.sh -------------------------------------------
assert_eq "imported rows are tagged with the capture filename" \
    "$PCAP" "$(sq1 "select tag from ssid where ssid_hex='$(hexof HomeNetwork)';")"

# pcap2db must tag with the filename even when ENGAGEMENT is set in the
# environment -- the pcap is the source of record for imported data, so the
# filename wins over the live-capture engagement name.
assert_eq "pcap filename wins over ENGAGEMENT" "$PCAP" \
    "$(ENGAGEMENT=should-not-appear sq1 "select tag from ssid where ssid_hex='$(hexof HomeNetwork)';")"

# --- ENGAGEMENT tags live-ingested rows ----------------------------------
# A row fed through ingest_stream (the live path) with ENGAGEMENT set carries
# it in tag; unset, the tag is NULL. Build one PROBE_SEP-separated line.
source "$REPO/capture-scripts/ingest_functions.sh"
line=$(printf '%s' "$(hexof EngTagNet)")
row_sep="${line}${PROBE_SEP}ab:cd:ef:00:11:22${PROBE_SEP}1700088000.100000${PROBE_SEP}-50${PROBE_SEP}2437${PROBE_SEP}100${PROBE_SEP}0x1${PROBE_SEP}${PROBE_SEP}${PROBE_SEP}${PROBE_SEP}${PROBE_SEP}"
ENGAGEMENT="op-nightfall" ingest_stream <<< "$row_sep" >/dev/null 2>&1
assert_eq "live ingest tags rows with ENGAGEMENT" "op-nightfall" \
    "$(sq1 "select tag from ssid where ssid_hex='$(hexof EngTagNet)';")"

mysql probeprint -e "delete from ssid where ssid_hex='$(hexof EngTagNet)';"
row_sep2="${line}2${PROBE_SEP}ab:cd:ef:00:11:33${PROBE_SEP}1700088001.100000${PROBE_SEP}-50${PROBE_SEP}2437${PROBE_SEP}101${PROBE_SEP}0x1${PROBE_SEP}${PROBE_SEP}${PROBE_SEP}${PROBE_SEP}${PROBE_SEP}"
ingest_stream <<< "$row_sep2" >/dev/null 2>&1
assert_eq "and leaves tag NULL when ENGAGEMENT is unset" "NULL" \
    "$(sq1 "select ifnull(tag,'NULL') from ssid where ssid_hex='$(hexof EngTagNet)2';")"

# --- Information Element fingerprint columns ------------------------------
# The IEs Pintor & Atzori measured as actually discriminative. Before this,
# only IE 191 (VHT) was captured -- their weakest and rarest feature.
row=$(sq1 "select concat_ws('/',ht,extcap,vendor_oui) from ssid where ssid_hex='$(hexof HomeNetwork)';")
assert_eq "IE 45 / 127 / 221 captured" \
    "0x09ef/0x04,0x00,0x40,0x00,0x00,0x00,0x00,0x40/6130,5271450" "$row"

# IE presence and ordering is a fingerprint independent of IE contents.
assert_eq "IE order captured" \
    "0,1,45,127,191,221,221" \
    "$(sq1 "select ie_order from ssid where ssid_hex='$(hexof HomeNetwork)';")"

# --- HT-Capabilities subfields and WPS UUID-E -----------------------------
# High-entropy HT subfields (Vanhoef 2016): captured into their own columns and
# folded into ie_fp. The fixture's HT element carries all four, so they populate.
assert_eq "HT A-MPDU parameters captured" "0" \
    "$(sq1 "select ht_ampdu is null from ssid where ssid_hex='$(hexof HomeNetwork)';")"
assert_eq "HT MCS set captured" "0" \
    "$(sq1 "select ht_mcsset is null from ssid where ssid_hex='$(hexof HomeNetwork)';")"
assert_eq "TxBF capabilities captured" "0" \
    "$(sq1 "select txbf is null from ssid where ssid_hex='$(hexof HomeNetwork)';")"
assert_eq "ASEL capabilities captured" "0" \
    "$(sq1 "select asel is null from ssid where ssid_hex='$(hexof HomeNetwork)';")"
# The fixture has no WPS IE, so UUID-E stays NULL -- and must not be a shifted
# value from a neighbouring column.
assert_eq "WPS UUID-E is NULL when absent" "NULL" \
    "$(sq1 "select ifnull(wps_uuid,'NULL') from ssid where ssid_hex='$(hexof HomeNetwork)';")"
# A frame with no HT element leaves all four HT subfields NULL, not shifted.
assert_eq "no HT element -> HT subfields NULL" "NULL/NULL/NULL/NULL" \
    "$(sq1 "select concat_ws('/',ifnull(ht_ampdu,'NULL'),ifnull(ht_mcsset,'NULL'),ifnull(txbf,'NULL'),ifnull(asel,'NULL')) from ssid where ssid_hex='$(hexof BareIeNet)';")"

# frame.len -- always present, a coarse model-level feature. Captured as the
# last positional field; a wrong count would leave it NULL or shifted.
assert_eq "frame length captured as a positive integer" "1" \
    "$(sq1 "select frame_len > 0 from ssid where ssid_hex='$(hexof HomeNetwork)' limit 1;")"

# ie_fp is a generated column, so it cannot drift from its inputs.
fp=$(sq1 "select ie_fp from ssid where ssid_hex='$(hexof HomeNetwork)';")
assert_eq "ie_fp is a 32-char md5" "32" "${#fp}"
# ie_fp now folds in the HT subfields.
assert_contains "ie_fp expression includes the HT subfields" "ht_mcsset" \
    "$(sq1 "select generation_expression from information_schema.columns where table_name='ssid' and column_name='ie_fp' and table_schema=database();")"

# Devices with identical IEs share a fingerprint; that is the point, and also
# the documented limitation (it identifies a model/OS build, not a person).
assert_eq "identical IE sets produce identical fingerprints" "1" \
    "$(sq1 "select count(distinct ie_fp) from ssid where ie_order='0,1,45,127,191,221,221';")"

# A frame carrying none of the fingerprint IEs must yield NULLs, not shifted
# values from neighbouring columns.
assert_eq "frame with no fingerprint IEs stores NULLs" "NULL/NULL/NULL" \
    "$(sq1 "select concat_ws('/',ifnull(ht,'NULL'),ifnull(extcap,'NULL'),ifnull(vendor_oui,'NULL')) from ssid where ssid_hex='$(hexof BareIeNet)';")"
assert_eq "frame with no fingerprint IEs keeps its own seq" "400" \
    "$(sq1 "select seq from ssid where ssid_hex='$(hexof BareIeNet)';")"

# --- backfill mode (INGEST_BACKFILL=1) ------------------------------------
# A field added after rows were first ingested is backfilled by re-parsing the
# capture -- but only with INGEST_BACKFILL=1. Plain insert-ignore leaves the
# existing row untouched, which is exactly the no-op backfill mode exists to
# override. Empty the two newest columns on an existing row, then prove each
# re-import path.
hn="$(hexof HomeNetwork)"
mysql probeprint -e "update ssid set frame_len = null, ht_ampdu = null where ssid_hex='$hn';"

# Default path: the row's timestamp already exists, so insert-ignore skips it.
./capture-scripts/pcap2db.sh "$PCAP" >/dev/null 2>&1
assert_eq "plain re-import leaves the emptied column NULL" "NULL" \
    "$(sq1 "select ifnull(frame_len,'NULL') from ssid where ssid_hex='$hn' limit 1;")"

# Backfill path: the upsert repopulates the columns added later, and leaves the
# tag (written on first import) in place.
INGEST_BACKFILL=1 ./capture-scripts/pcap2db.sh "$PCAP" >/dev/null 2>&1
assert_eq "backfill re-import repopulates frame_len" "1" \
    "$(sq1 "select frame_len > 0 from ssid where ssid_hex='$hn' limit 1;")"
assert_eq "and repopulates the HT subfield" "0" \
    "$(sq1 "select ht_ampdu is null from ssid where ssid_hex='$hn' limit 1;")"
assert_eq "backfill preserves the original tag" "$PCAP" \
    "$(sq1 "select tag from ssid where ssid_hex='$hn' limit 1;")"

finish
