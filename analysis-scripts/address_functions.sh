#!/bin/bash
# check_address -- street-address-shaped SSIDs, which is what fills LOCATION_SPECIFIC.
#
# "1190 Lowell", "111 Avenue G": a house number followed by a street name. Worth
# separating because it is a residential origin signal, and worth NOT confusing
# with a venue name -- online_places.sh excludes this category for exactly that
# reason.
check_address () {
	echo address start $(date +"%H:%M:%S.%3N")

	# One statement. This was a shell loop that forked `xxd` and `egrep` per
	# candidate row and issued a `mysql` per match; the regex runs perfectly well
	# in SQL against the decoded SSID, so none of that was buying anything.
	# Verified against the previous implementation on a real collection: same
	# rows selected, zero disagreement.
	#
	# The pattern is unchanged, including the odd `[\\.a-z]` class -- a
	# backslash, a period, or a lowercase letter -- which is what lets
	# "1 St. James" through. `unhex()` yields binary, so the match is bytewise
	# and needs no charset handling for this ASCII pattern.
	#
	# Restricted to ssid_hex like '3%' as before: the first byte is 0x3X, so the
	# name begins with a digit. An address that does not start with its number
	# was never in scope.
	mysql probeprint <<'SQL'
update ssid_intel
   set category = "LOCATION_SPECIFIC"
 where ssid_hex like '3%'
   and unhex(ssid_hex) regexp '^[0-9]{1,5} ?[A-Z][\\.a-z] ?[a-zA-Z]';
SQL
	echo "  address-shaped SSIDs: $(mysql -N probeprint <<< "select count(*) from ssid_intel where category='LOCATION_SPECIFIC';")"
	echo check address stop $(date +"%H:%M:%S.%3N")
}
