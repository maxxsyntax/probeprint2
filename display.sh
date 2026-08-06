#!/usr/bin/bash
# Live operator display: what is probing right now, and which device it is.
#
# Reuses the shared helpers rather than carrying its own inline copies of the
# RSSI bucketing and intel lookup.
#set -x
source ./display_functions.sh

# The capture host runs mariadb locally; a display on another machine can point
# elsewhere by setting DISPLAY_DB_ARGS in .env.
[ -f .env ] && source .env
DISPLAY_DB_ARGS=${DISPLAY_DB_ARGS:--u pi -h 127.0.0.1}

WINDOW=${DISPLAY_WINDOW:-5}

clear
start_date=$(date +%s)

while true; do
	clear
	end_date=$(( $(date +%s) - WINDOW ))

	tput cup 0 0
	printf 'probeprint2   frames this session: %s   devices: %s   suspect merges: %s\n' \
		"$(dq <<< "select count(*) from ssid where cast(time as decimal(20,7)) > $start_date;")" \
		"$(dq <<< "select count(*) from devices;")" \
		"$(dq <<< "select count(*) from devices where confidence='low';")"
	printf '%s\n\n' "----------------------------------------------------------------"

	# One block per (device, network) seen in the window. Grouping by device_id
	# means a phone that rotated its MAC mid-window shows as one device, not
	# several -- which is the whole point of the sequence graph.
	while IFS='|' read -r device_id ssid_hex rssi; do
		[ -z "$ssid_hex" ] && continue

		ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null | tr -cd '[:print:]')
		range=$(rssi_range "$rssi")

		device_banner "$device_id"
		printf '  %s' "$ssid"
		[ -n "$range" ] && printf '   [%s]' "$range"
		printf '\n'

		dq <<SQL | while IFS=$'\t' read -r loc cat name airport; do
select ifnull(nullif(location,'0'),''), ifnull(category,''),
       ifnull(nullif(is_name,'0'),''), ifnull(nullif(is_airport,'0'),'')
  from ssid_intel
 where ssid_hex = "$ssid_hex" and ssid_hex <> '<MISSING>';
SQL
			[ -n "$cat" ] && [ "$cat" != "OTHER_UNKNOWN" ] && printf '    %s\n' "$cat"
			[ -n "$loc" ]     && printf '    %s\n' "$loc"
			[ -n "$name" ]    && printf '    name: %s\n' "$name"
			[ -n "$airport" ] && printf '    airport: %s\n' "$airport"
		done
		printf '\n'
	done <<< "$(dq <<SQL
select concat_ws('|', ifnull(device_id,''), ssid_hex, ifnull(rssi,''))
  from ssid
 where cast(time as decimal(20,7)) > $end_date
   and ssid_hex <> '<MISSING>'
 group by device_id, ssid_hex
 order by cast(rssi as signed) desc;
SQL
)"

	sleep "$WINDOW"
done
