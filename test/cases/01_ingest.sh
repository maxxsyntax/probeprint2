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
./pcap2db.sh "$PCAP" >/tmp/ingest.log 2>&1

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

# ie_fp is a generated column, so it cannot drift from its inputs.
fp=$(sq1 "select ie_fp from ssid where ssid_hex='$(hexof HomeNetwork)';")
assert_eq "ie_fp is a 32-char md5" "32" "${#fp}"

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

finish
