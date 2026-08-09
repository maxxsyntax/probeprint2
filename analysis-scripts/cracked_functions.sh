#!/bin/bash
# check_cracked -- flag SSIDs whose WPA password is publicly known.
#
# lists/cracked.txt is a set of SSID names, one lowercase-hex per line, for
# which a password is recoverable -- default-password networks, entries in
# public WPA wordlists, previously cracked handshakes. A device probing for one
# is a soft target: the network can be stood up with the known password and the
# device will associate to it, so it is worth flagging in the operator display.
#
# A property of the SSID string against a shipped list, exactly like is_common,
# so it is done the same way -- one batched pass, null-driven, idempotent.
check_cracked () {
	local recompute=${1:-}
	local guard="and is_cracked is null"
	[ "$recompute" = "--recompute" ] && guard=""

	echo "check_cracked start $(date +"%H:%M:%S.%3N")"

	if [ ! -s lists/cracked.txt ]; then
		echo "  lists/cracked.txt is missing or empty -- nothing to match." >&2
		return 1
	fi

	# The list is loaded into a temp table and matched with a join, rather than
	# a query per SSID. varbinary + 0x literals so the byte sequence is compared
	# exactly and no charset transcoding can alter it. Blank lines and comments
	# are skipped in the awk; `insert ignore` absorbs the list's own duplicates.
	local sqlf; sqlf=$(mktemp)
	{
		echo "create temporary table _cracked (h varbinary(255) primary key);"
		echo "insert ignore into _cracked (h) values"
		awk 'NF && $1 !~ /^#/ {printf "%s(0x%s)", (seen++ ? "," : ""), $1}' lists/cracked.txt
		echo ";"
		# Matches to 1, non-matches to 0, over the same candidate set (rows not
		# yet checked, or every row under --recompute).
		#
		# The second statement is a LEFT JOIN keeping only c.h IS NULL -- the
		# non-matches -- rather than a blanket `set 0`. That blanket form was
		# wrong under --recompute: with the guard empty it set every row to 0,
		# including the matches the first statement had just set to 1. Targeting
		# the non-matches explicitly is correct in both modes.
		echo "update ssid_intel i join _cracked c on c.h = unhex(i.ssid_hex)
		         set i.is_cracked = 1 where 1=1 $guard;"
		echo "update ssid_intel i left join _cracked c on c.h = unhex(i.ssid_hex)
		         set i.is_cracked = 0 where c.h is null $guard;"
	} > "$sqlf"
	mysql probeprint < "$sqlf"
	rm -f "$sqlf"

	echo "  password known (is_cracked=1) : $(mysql -N probeprint <<< "select count(*) from ssid_intel where is_cracked=1;")"
	echo "check_cracked stop $(date +"%H:%M:%S.%3N")"
}
