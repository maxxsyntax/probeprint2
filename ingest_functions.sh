#!/bin/bash
# Shared 802.11 probe-request ingest.
#
# Sourced by build_ssid.sh (single host), client/build_ssid.sh (distributed
# capture nodes) and pcap2db.sh (offline backfill). All three previously had
# their own copy of this parse loop, so a fix in one left the other two broken.
#
# --- Why the separator is '|' and not a tab -------------------------------
# These scripts originally asked tshark for a space separator and then split
# with `arr=($line)`. Bash collapses runs of IFS *whitespace*, so any empty
# middle field -- a probe with no RSSI, or no channel -- shifted every later
# column one place left: the timestamp landed in rssi, the sequence number
# landed in vht. That silently corrupted the `ssid` table, which everything
# downstream reads.
#
# Switching to tshark's default tab does NOT fix this: tab is also IFS
# whitespace, so `IFS=$'\t' read` collapses it just the same. Verified
# empirically -- tshark emits the empty field correctly (two adjacent
# delimiters), bash then throws it away.
#
# '|' is not IFS whitespace, so adjacent delimiters produce genuine empty
# fields. It is also safe for this field set: SSIDs arrive hex-encoded, MACs
# are hex and colons, time/rssi/freq/seq are numeric and vht is 0x-hex. ','
# is unusable because tshark uses it to join multiple occurrences of one field
# (multi-antenna RSSI arrives as "-42,-45").
PROBE_SEP='|'

# Field order is defined once here and consumed positionally by ingest_stream().
# Keep the two in sync.
PROBE_TSHARK_ARGS=(
    -T fields
    -e wlan.ssid
    -e wlan.sa
    -e frame.time_epoch
    -e radiotap.dbm_antsignal
    -e wlan_radio.frequency
    -e wlan.seq
    -e wlan.vht.capabilities
    -E "separator=$PROBE_SEP"
)

# ingest_stream [mysql-args...]
#
# Read '|'-separated tshark field output on stdin, log a human-readable summary
# and insert one row per probe request. Any extra arguments are passed through
# to mysql, which is how the distributed nodes target the central server
# (ingest_stream -u pi -h 192.168.1.10).
ingest_stream () {
    local ssid_hex wlan_sa time rssi freq seq vht

    while IFS="$PROBE_SEP" read -r ssid_hex wlan_sa time rssi freq seq vht; do
        # tshark emits a trailing blank line at the end of each capture window,
        # and a row with no timestamp is not a usable observation.
        [ -z "$time" ] && continue

        if [ "$ssid_hex" != "<MISSING>" ]; then
            echo "ssid_hex is $ssid_hex"
            echo "ssid is $(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null)"
            echo "sa is $wlan_sa"
            echo "time is $time"
            echo "rssi is $rssi"
            echo "freq is $freq"
            echo "seq is $seq"
            echo "vht is $vht"
        else
            # A wildcard probe with a zero-length SSID. tshark reports the
            # literal string <MISSING>, and downstream queries filter on it,
            # so it is stored verbatim rather than normalised to NULL.
            echo "Broadcast Detected $wlan_sa time is $time $rssi seq is $seq"
        fi

        # freq and seq are integer columns, so an empty capture field has to go
        # in as NULL -- MariaDB's default strict mode rejects ''.
        #
        # `insert ignore` because `time` is the primary key: two frames sharing
        # a timestamp collide. Previously pcap2db.sh retried the identical
        # failing insert in a loop, which can never succeed and span forever.
        mysql "$@" probeprint <<SQL
insert ignore into ssid (ssid_hex, wlan_sa, time, rssi, freq, seq, vht)
values ("$ssid_hex", "$wlan_sa", "$time", "$rssi",
        nullif("$freq", ''), nullif("$seq", ''), "$vht");
SQL
    done
}
