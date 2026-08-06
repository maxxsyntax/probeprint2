#!/bin/bash
# Operator display helpers.
#
# Ported from sqlite3 to MariaDB. This file previously queried ssid.db,
# ssid_intel.db and bursts.db, which stopped existing when the pipeline moved to
# MySQL -- it could not run at all. Everything now reads the `probeprint`
# database, matching display.sh and the rest of the tree.
#
# Connection settings, overridable from .env so a display can run on a laptop
# against the collection host.
DISPLAY_DB_ARGS=${DISPLAY_DB_ARGS:-}

dq () { mysql -N $DISPLAY_DB_ARGS probeprint "$@"; }

# rssi_range <rssi>
# Coarse proximity bucket.
#
# NOTE: fixed thresholds do not travel between sites. Cheshire et al. found
# signal decay is not constant with distance once transmit power, obstructions
# and atmospherics vary, and used a break in the RSSI *distribution* instead.
# These constants are a stopgap; see FINGERPRINTING.md.
rssi_range () {
	local r=${1%%,*}                       # multi-antenna arrives as "-42,-45"
	[ -z "$r" ] && { echo ""; return; }
	if [ "$r" -gt -66 ] 2>/dev/null; then
		[ "$r" -ne 0 ] && echo "near by"
	elif [ "$r" -gt -82 ] 2>/dev/null; then
		echo "medium range"
	else
		echo "far away"
	fi
}

# device_banner <device_id>
# One line identifying the device behind a probe: its friendly alias, how much
# corroboration there is, and the vendor if resolvable.
#
# The alias is a display handle only -- devices.id is the identity. A device
# flagged low confidence spans more than one IE signature, which one physical
# device cannot do, so it is probably two devices merged in error.
device_banner () {
	local id=$1
	[ -z "$id" ] || [ "$id" = "NULL" ] && return

	dq <<SQL | while IFS=$'\t' read -r alias conf macs ssids vendor; do
select ifnull(alias,concat('device ',id)),
       ifnull(confidence,'unknown'),
       mac_count, ssid_count, ifnull(vendor,'')
  from devices where id = $id;
SQL
		printf 'Device: %s' "$alias"
		[ -n "$vendor" ] && printf ' [%s]' "$vendor"
		case "$conf" in
			low)     printf '  (!! low confidence: %s IE signatures, likely two devices merged)' \
			                "$(dq <<< "select ie_fp_distinct from devices where id = $id;")" ;;
			high)    printf '  (confirmed across %s MACs)' "$macs" ;;
			unknown) printf '  (unverified: no IE data)' ;;
		esac
		printf '\n'
		[ "$macs" -gt 1 ] 2>/dev/null && printf '  randomization defeated: %s addresses, %s networks\n' "$macs" "$ssids"
	done
}

# --- the in-range profile view ----------------------------------------------
#
# One block per device currently probing, nearest first, with everything the
# pipeline knows about that fingerprint assembled from its preferred network
# list. This is the view the README describes: vetting someone in front of you
# against what their device is broadcasting.
#
# Fields are separated by char(31), the ASCII unit separator, rather than a
# printable character. SSIDs are arbitrary bytes and routinely contain '|', ','
# and tabs, any of which would split a row in the wrong place.

# device_profile_rows <cutoff_epoch>
# One char(31)-separated row per device heard since the cutoff.
device_profile_rows () {
	local cutoff=$1
	dq <<SQL
select concat_ws(char(31),
    d.id,
    ifnull(d.alias, concat('device ', d.id)),
    ifnull(d.confidence, 'unknown'),
    ifnull(d.vendor, ''),
    r.best_rssi,
    d.pnl_size,
    ifnull(round(d.pnl_rarity, 0), 0),
    ifnull((select group_concat(distinct i.is_name order by i.is_name separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.is_name is not null
               and i.is_name not in ('0','')), ''),
    ifnull((select group_concat(distinct unhex(ds.ssid_hex) separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.category = 'OTHER_HOUSEHOLD'), ''),
    ifnull((select group_concat(distinct unhex(ds.ssid_hex) separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id
               and i.category in ('BIZ_STAFF','INDUSTRY_ORG','BIZ_COWORK','BIZ_INSTITUTION')), ''),
    ifnull((select group_concat(distinct i.lang separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.lang_scope = 'language'), ''),
    ifnull((select group_concat(distinct concat(i.cpe_isp,' (',i.cpe_country,')') separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.cpe_scope = 'country'), ''),
    -- Whichever level of detail geolocation actually reached: a reverse-geocoded
    -- street address if Nominatim ran, else the WiGLE text summary, else the raw
    -- coordinates. Empty is only correct when none of the three exists.
    ifnull((select group_concat(distinct coalesce(
                      nullif(i.street_address,''),
                      nullif(nullif(nullif(nullif(nullif(i.location,'0'),'no file'),'no results'),'too many results'),'no match for ssid'),
                      case when i.lat is not null then concat(round(i.lat,4),',',round(i.lon,4)) end
                   ) separator '; ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id
               and (i.street_address is not null or i.lat is not null
                    or i.location not in ('0','no file','no results','too many results','no match for ssid'))), ''),
    ifnull((select group_concat(distinct i.is_airport separator '; ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.is_airport is not null
               and i.is_airport not in ('0','')), ''),
    ifnull((select group_concat(distinct unhex(ds.ssid_hex) separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.category in ('BIZ_HOTEL','TRAVEL')), ''),
    ifnull((select group_concat(distinct unhex(ds.ssid_hex) separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.category = 'BIZ_EATERY'), ''),
    ifnull((select group_concat(distinct unhex(ds.ssid_hex) separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.rarity > 15
               and i.category not in ('TECH_CPE','OTHER_ANOMALOUS')), ''),
    d.mac_count)
  from devices d
  join (select device_id, max(cast(rssi as signed)) as best_rssi
          from ssid
         where device_id is not null
           and cast(time as decimal(20,7)) > $cutoff
         group by device_id) r on r.device_id = d.id
 order by r.best_rssi desc
 limit 40;
SQL
}

# display_inrange [seconds]
#
# The operator view. Nearest device first, with its profile.
display_inrange () {
	local window=${1:-30}
	local cutoff
	cutoff=$(date +%s --date="$window sec ago")

	local id alias conf vendor rssi pnl rarity names household employer \
	      lang market places airports travel eatery rare macs
	local shown=0

	while IFS=$'\037' read -r id alias conf vendor rssi pnl rarity names household \
	                          employer lang market places airports travel eatery rare macs; do
		[ -z "$id" ] && continue
		shown=$((shown + 1))

		printf '%s  [%s]' "$alias" "$(rssi_range "$rssi")"
		[ -n "$vendor" ] && printf '  %s' "$vendor"
		printf '\n'

		# A low-confidence device spans several IE signatures, which one physical
		# device cannot do. Everything below it is then a blend of two people's
		# networks, so the warning has to come before the profile, not after.
		case "$conf" in
			low)     printf '  !! UNRELIABLE: this fingerprint spans several devices -- treat the profile as mixed\n' ;;
			unknown) printf '  (unverified: no IE data to corroborate)\n' ;;
		esac
		[ "${macs:-1}" -gt 1 ] 2>/dev/null && printf '  seen under %s rotating addresses\n' "$macs"

		[ -n "$names" ]     && printf '  Name        : %s\n' "$names"
		[ -n "$household" ] && printf '  Household   : %s\n' "$household"
		[ -n "$employer" ]  && printf '  Employer    : %s\n' "$employer"
		[ -n "$lang" ]      && printf '  Language    : %s\n' "$lang"
		[ -n "$market" ]    && printf '  Home ISP    : %s\n' "$market"
		[ -n "$places" ]    && printf '  Places      : %s\n' "$places"
		[ -n "$airports" ]  && printf '  Airports    : %s\n' "$airports"
		[ -n "$travel" ]    && printf '  Hotels/tvl  : %s\n' "$travel"
		[ -n "$eatery" ]    && printf '  Eateries    : %s\n' "$eatery"
		[ -n "$rare" ]      && printf '  Rare nets   : %s\n' "$rare"

		# pnl_rarity is how identifying the whole list is. A high score means
		# this person could be picked out of a large population by their
		# networks alone.
		printf '  %s networks, identifiability %s\n\n' "$pnl" "$rarity"
	done <<< "$(device_profile_rows "$cutoff")"

	[ "$shown" -eq 0 ] && echo "(nothing in range in the last ${window}s)"
}

# display_recent [seconds]
# Everything seen in the last N seconds, grouped by the device behind it.
display_recent () {
	local window=${1:-30}
	local cutoff
	cutoff=$(date +%s --date="$window sec ago")

	while IFS='|' read -r device_id ssid_hex rssi; do
		[ -z "$ssid_hex" ] && continue

		local ssid range
		ssid=$(printf '%s' "$ssid_hex" | xxd -r -p 2>/dev/null | tr -cd '[:print:]')
		range=$(rssi_range "$rssi")

		device_banner "$device_id"
		printf 'Network: %s\n' "$ssid"
		[ -n "$range" ] && printf '  Proximity: %s (%s)\n' "$range" "${rssi%%,*}"

		# Intel for this SSID. OTHER_UNKNOWN and the zero placeholders are noise
		# on a live display, so they are filtered rather than printed.
		dq <<SQL | while IFS=$'\t' read -r cat loc name airport rarity; do
select ifnull(category,''), ifnull(location,''), ifnull(is_name,''),
       ifnull(is_airport,''), ifnull(round(rarity,1),'')
  from ssid_intel where ssid_hex = "$ssid_hex";
SQL
			[ -n "$cat" ] && [ "$cat" != "OTHER_UNKNOWN" ] && printf '  Category: %s\n' "$cat"
			[ -n "$loc" ] && [ "$loc" != "0" ] && printf '  Location: %s\n' "$loc"
			[ -n "$name" ] && [ "$name" != "0" ] && printf '  Name: %s\n' "$name"
			[ -n "$airport" ] && [ "$airport" != "0" ] && printf '  Airport: %s\n' "$airport"
			# High rarity means few other devices anywhere probe for this, which
			# is what makes it useful for linking people.
			[ -n "$rarity" ] && awk -v r="$rarity" 'BEGIN{exit !(r>12)}' \
				&& printf '  Rare network (rarity %s)\n' "$rarity"
		done
		printf '\n'
	done <<< "$(dq <<SQL
select concat_ws('|', ifnull(device_id,''), ssid_hex, ifnull(rssi,''))
  from ssid
 where cast(time as decimal(20,7)) > $cutoff
   and ssid_hex <> '<MISSING>'
 group by device_id, ssid_hex
 order by cast(rssi as signed) desc;
SQL
)"
}

# display_devices
# Roster of every device seen, worst-corroborated first so a bad merge is
# visible rather than buried.
display_devices () {
	printf '%-26s %-11s %7s %5s %6s %-16s %s\n' \
		"alias" "confidence" "frames" "macs" "ssids" "vendor" "last seen"
	dq <<'SQL' | awk -F'\t' '{ printf "%-26s %-11s %7s %5s %6s %-16s %s\n", $1,$2,$3,$4,$5,$6,$7 }'
select ifnull(alias, concat('device ', id)),
       ifnull(confidence,'-'),
       frame_count, mac_count, ssid_count,
       ifnull(substr(vendor,1,16),'-'),
       ifnull(from_unixtime(cast(last_seen as decimal(20,0))),'-')
  from devices
 order by (confidence = 'low') desc, mac_count desc, frame_count desc;
SQL
}

# display_device <alias-or-id>
# Everything known about one device, including its full preferred network list
# ordered by rarity -- the rare entries are the ones that identify a person.
display_device () {
	local who=$1
	local id
	id=$(dq <<< "select id from devices where alias = \"$who\" or id = nullif('$who','') limit 1;")
	if [ -z "$id" ]; then
		echo "no such device: $who" >&2
		return 1
	fi

	device_banner "$id"
	echo
	echo "Preferred networks (rarest first -- rare entries are the identifying ones):"
	dq <<SQL | awk -F'\t' '{ printf "  %-34s %6s  %s\n", $1, $2, $3 }'
select distinct
       substr(unhex(s.ssid_hex),1,34),
       ifnull(round(i.rarity,1),'-'),
       ifnull(nullif(i.location,'0'),'')
  from ssid s
  left join ssid_intel i on i.ssid_hex = s.ssid_hex
 where s.device_id = $id
   and s.ssid_hex <> '<MISSING>'
 order by i.rarity desc;
SQL
}
