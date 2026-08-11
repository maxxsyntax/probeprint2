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
    -- Networks in this device's PNL whose password is publicly known AND which
    -- are rare. A soft target: the network can be impersonated with the known
    -- key to draw the device onto it. Rarity is the qualifier that makes it
    -- actionable -- a cracked 'linksys' or 'xfinitywifi' is on thousands of
    -- devices and impersonating it targets nobody, whereas a cracked rare
    -- network belongs to one household and re-creating it lures that person's
    -- device specifically. Same rarity > 15 bar as the Rare nets line above.
    ifnull((select group_concat(distinct unhex(ds.ssid_hex) separator ', ')
              from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id and i.is_cracked = 1 and i.rarity > 15), ''),
    d.mac_count,
    -- Seconds since this device was last seen BEFORE the current visit. The
    -- >3600 gap is what makes it a prior visit rather than the same one still
    -- in progress: a device probing continuously for ten minutes has sightings
    -- seconds apart, and none of those is a "previous time". A returning device
    -- -- here today, here last week -- is a far stronger intel signal than
    -- anything in its network list, so it is computed here and shown first.
    ifnull((select $cutoff - max(cast(s.time as decimal(20,7)))
              from ssid s
             where s.device_id = d.id
               and cast(s.time as decimal(20,7)) < $cutoff - 3600), -1))
  from devices d
  join (select device_id, max(cast(rssi as signed)) as best_rssi
          from ssid
         where device_id is not null
           and cast(time as decimal(20,7)) > $cutoff
         group by device_id) r on r.device_id = d.id
 -- The dossier leads with people, so the roster does too: a device carrying a
 -- human identity (a name, a household, an employer, a language) sorts ahead of
 -- an anonymous one regardless of signal, and a returning subject ahead of a
 -- first-time one. Signal only decides within those groups.
 order by
   (exists (select 1 from device_ssid ds join ssid_intel i on i.ssid_hex = ds.ssid_hex
             where ds.device_id = d.id
               and (   (i.is_name is not null and i.is_name not in ('0',''))
                    or i.category = 'OTHER_HOUSEHOLD'
                    or i.category in ('BIZ_STAFF','INDUSTRY_ORG','BIZ_COWORK','BIZ_INSTITUTION')
                    or i.lang_scope = 'language'))) desc,
   (exists (select 1 from ssid s where s.device_id = d.id
             and cast(s.time as decimal(20,7)) < $cutoff - 3600)) desc,
   r.best_rssi desc
 limit 40;
SQL
}

# human_duration <seconds>  -- a coarse, operator-readable age. Precision beyond
# the largest unit is noise when the point is "was this device here before".
human_duration () {
	local s=$1
	if   [ "$s" -lt 5400 ]; then echo "about an hour ago"
	elif [ "$s" -lt 86400 ]; then echo "$(( (s + 1800) / 3600 )) hours ago"
	elif [ "$s" -lt 172800 ]; then echo "yesterday"
	else echo "$(( (s + 43200) / 86400 )) days ago"
	fi
}

# display_inrange [seconds]
#
# The operator view. Nearest device first, with its profile.
display_inrange () {
	local window=${1:-30}
	local cutoff
	cutoff=$(date +%s --date="$window sec ago")

	local id alias conf vendor rssi pnl rarity names household employer \
	      lang market places airports travel eatery rare cracked macs last_prior
	local shown=0

	local quiet=0 quiet_near=""
	while IFS=$'\037' read -r id alias conf vendor rssi pnl rarity names household \
	                          employer lang market places airports travel eatery rare cracked macs last_prior; do
		[ -z "$id" ] && continue
		shown=$((shown + 1))

		# A device that has probed no usable network -- empty PNL, zero
		# identifiability, and nothing the enrichment surfaced -- has nothing to
		# put in a dossier. Rendering a full block for it (a header and a bare
		# "Preferred nets: 0, identifiability 0") is noise, and on a real capture
		# these are the majority. But they must not vanish: the operator needs to
		# see that signal is arriving, so they are counted and the nearest is
		# named in a one-line summary after the dossiers, rather than dropped.
		if [ "${pnl:-0}" -le 0 ] 2>/dev/null && [ "${rarity:-0}" -le 0 ] 2>/dev/null \
		   && [ -z "$names$household$employer$lang$market$places$airports$travel$eatery$rare$cracked" ]; then
			quiet=$((quiet + 1))
			if [ -z "$quiet_near" ]; then
				local band; band=$(rssi_range "$rssi")
				quiet_near="$alias${band:+ [$band]}"
			fi
			continue
		fi

		# --- DEVICE line first ------------------------------------------------
		# The header is the DEVICE, not the subject. An earlier version led with
		# the person, but a perceived human identity is the exception -- most
		# devices never reveal a name -- whereas the fingerprint alias is always
		# present. Leading with the thing that is reliably there, and letting the
		# human identity follow as a SUBJECT section when there is one, reads
		# better in a room full of anonymous devices.
		printf '=== %s' "$alias"
		[ -n "$vendor" ] && printf ' [%s]' "$vendor"
		printf '   [%s]' "$(rssi_range "$rssi")"
		[ "${last_prior:--1}" -ge 0 ] 2>/dev/null && printf '   SEEN BEFORE: %s' "$(human_duration "$last_prior")"
		printf '\n'

		# A low-confidence device is two people's networks blended into one
		# dossier, so the warning has to precede the profile an operator reads
		# top-down.
		case "$conf" in
			low)     printf '  !! UNRELIABLE: this fingerprint spans several devices -- profile may be two people\n' ;;
			unknown) printf '  (unverified: no IE data to corroborate this grouping)\n' ;;
		esac
		[ "${macs:-1}" -gt 1 ] 2>/dev/null && printf '  Fingerprint  : %s rotating MACs\n' "$macs"
		# pnl_rarity is how identifying the whole list is: high means this person
		# could be singled out of a large crowd by their networks alone.
		printf '  Preferred nets: %s, identifiability %s\n' "$pnl" "$rarity"
		[ -n "$cracked" ]   && printf '  Soft target  : %s (password known)\n' "$cracked"

		# --- SUBJECT: what is known about the person, if anything -------------
		# Named only when at least one human trait is present, so an anonymous
		# device does not sprout an empty "SUBJECT: Unidentified" header.
		local subject
		if   [ -n "$names" ]; then subject="$names"
		elif [ -n "$household" ]; then subject="$household (household)"
		elif [ -n "$employer" ]; then subject="$employer (workplace)"
		else subject=""
		fi
		[ -n "$subject" ] && printf '  SUBJECT     : %s\n' "$subject"

		[ -n "$names" ]     && printf '  Name        : %s\n' "$names"
		[ -n "$household" ] && printf '  Household    : %s\n' "$household"
		[ -n "$employer" ]  && printf '  Employer     : %s\n' "$employer"
		[ -n "$lang" ]      && printf '  Language     : %s\n' "$lang"
		[ -n "$market" ]    && printf '  Home region  : %s\n' "$market"
		# Everywhere the network list places them, merged under one heading --
		# an operator wants "where does this person go", not four label variants.
		local frequents="" f
		for f in "$places" "$travel" "$eatery" "$airports"; do
			[ -n "$f" ] && frequents="${frequents:+$frequents; }$f"
		done
		[ -n "$frequents" ] && printf '  Frequents    : %s\n' "$frequents"
		[ -n "$rare" ]      && printf '  Notable nets : %s\n' "$rare"
		printf '\n'
	done <<< "$(device_profile_rows "$cutoff")"

	# The quiet devices, as one reassuring line rather than pages of empty blocks.
	# Proof that signal is flowing even when nobody in range is broadcasting a
	# usable network name.
	if [ "$quiet" -gt 0 ]; then
		if [ "$quiet" -eq 1 ]; then
			printf '+ 1 device in range probing no usable networks (%s)\n\n' "$quiet_near"
		else
			printf '+ %s devices in range probing no usable networks (nearest: %s)\n\n' \
			       "$quiet" "$quiet_near"
		fi
	fi

	# Everything above is keyed on devices, so a frame whose device_id is still
	# null cannot appear in it however strong the signal. seqgraph is a batch
	# pass, and during a live engagement it may simply never run -- not enough
	# CPU, frames arriving too fast. That is a normal operating state, not an
	# error, and the display has to stay useful in it.
	#
	# So ungrouped traffic is shown as what it is: raw observations, keyed on
	# the transmitting address, which needs no enrichment at all. An SSID and a
	# proximity band are most of the value here anyway. No instruction to go run
	# something -- the operator is standing in a room, not at a terminal.
	local raw=0
	display_ungrouped "$cutoff" && raw=1

	# The window length is an implementation detail the operator does not care
	# about -- "the last 30s" reads as a bug when they have been staring at it
	# for three. Just state that the air is empty.
	[ "$shown" -eq 0 ] && [ "$raw" -eq 0 ] && \
		echo "Zero Signals Observed"
}

# display_ungrouped <cutoff_epoch>
#
# List frames in the window that no device owns yet, one line per transmitting
# address, newest first. Returns 1 when there are none.
#
# Deliberately cheap: one query, no joins to ssid_intel or device_ssid, so it
# costs the same whether or not any enrichment pass has ever run.
display_ungrouped () {
	local cutoff=$1 mac rssi ssids n any=0

	while IFS=$'\037' read -r mac rssi n ssids; do
		[ -z "$mac" ] && continue
		if [ "$any" -eq 0 ]; then
			printf 'Not yet grouped -- raw probes in this window\n'
			any=1
		fi
		printf '  %s  [%s]  %s\n' "$mac" "$(rssi_range "$rssi")" "${ssids:-(broadcast only)}"
	done <<< "$(mysql -N probeprint <<SQL
select concat_ws(char(31),
       s.wlan_sa,
       max(cast(substring_index(s.rssi, ',', 1) as signed)),
       count(*),
       -- The wildcard probe is stored as the literal string <MISSING>, which is
       -- not hex; unhex() would return NULL and swallow the whole row.
       ifnull(group_concat(distinct
              case when s.ssid_hex = '<MISSING>' then null
                   else convert(unhex(s.ssid_hex) using utf8mb4) end
              order by s.ssid_hex separator ', '), ''))
  from ssid s
 where cast(s.time as decimal(20,7)) > $cutoff
   and s.device_id is null
   and s.wlan_sa is not null
 group by s.wlan_sa
 order by max(cast(substring_index(s.rssi, ',', 1) as signed)) desc
 limit 40;
SQL
)"

	[ "$any" -eq 1 ]
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
