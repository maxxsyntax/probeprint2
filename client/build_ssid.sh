#!/bin/bash
#set -x
source .env
# The parse loop is shared with the single-host build_ssid.sh and pcap2db.sh.
source ../ingest_functions.sh

INF=$1
mkfifo "pipe_$INF" 2>/dev/null

# Central database on the collection server. Overridable from .env so a node
# can be pointed elsewhere without editing this script.
DB_HOST=${DB_HOST:-192.168.1.10}
DB_USER=${DB_USER:-pi}

listen () {
#iwconfig $INF channel 6
 while true; do

tshark -Qi "$INF" -a duration:3 -f "wlan subtype probe-req" "${PROBE_TSHARK_ARGS[@]}" 2>/dev/null > "pipe_$INF"
done
}

tshark2db () {
while true; do
	ingest_stream -u "$DB_USER" -h "$DB_HOST" < "pipe_$INF"
	sleep .1
done
}

listen &
tshark2db &



trap 'kill $(jobs -p)' EXIT
wait
