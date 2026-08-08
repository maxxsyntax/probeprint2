#!/bin/bash
# Continuous SSID rarity scoring.
#
# Cunche, Kaafar & Boreli (WoWMoM 2012) showed that linking two devices -- and
# therefore two people -- by their preferred network lists depends on how *rare*
# the SSIDs they share are, not on how many they share. Their Jaccard index
# baseline, which sees only presence/absence, was the worst performing metric
# they tested; every metric that weighted by rarity beat it.
#
# This pipeline's existing `is_common` flag is exactly that worst case: a binary
# in-the-list / not-in-the-list test. These functions add the continuous score.
#
#   f(z)      = total sightings of SSID z / total sightings of all SSIDs
#   rarity(z) = -ln f(z)
#
# On the shipped lists/ssid.csv (208k SSIDs, 368.6M sightings) that puts
# "xfinitywifi" at about 2.8 and an SSID seen 250 times at about 14.2. An SSID
# absent from the corpus entirely is treated as maximally rare, ln(corpus),
# about 19.7 -- these are the personal and workplace network names that carry
# nearly all the linkage signal.
#
# is_common is left in place; nothing that reads it needs to change.

# load_ssid_frequencies [--reload]
#
# Populate the ssid_freq lookup table from lists/ssid.csv. Skips the work if the
# table is already populated, since the source list only changes when it is
# re-downloaded from wigle.net/csv/ssid.csv.
load_ssid_frequencies () {
	local existing
	existing=$(mysql -N probeprint <<< "select count(*) from ssid_freq;")

	if [ "${1:-}" != "--reload" ] && [ "${existing:-0}" -gt 0 ]; then
		echo "ssid_freq already holds $existing rows (pass --reload to rebuild)"
		return 0
	fi

	echo "loading lists/ssid.csv into ssid_freq $(date +"%H:%M:%S.%3N")"
	mysql probeprint <<< "truncate table ssid_freq;"

	# Batched multi-row INSERTs rather than one statement per row: the list is
	# 208k SSIDs and a round trip each would take hours.
	#
	# LC_ALL=C so awk's length()/substr() count bytes, not characters -- SSIDs
	# are arbitrary byte strings and many in this list are UTF-8.
	#
	# Splitting on the *first* comma only, because an SSID may itself contain
	# commas ("250, Timber-Guest" is a real entry). Hex-encoding sidesteps SQL
	# quoting entirely, which matters when the data contains quotes and
	# backslashes.
	LC_ALL=C awk -v BATCH=1000 '
	BEGIN {
		for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
		n = 0
	}
	NR == 1 { next }                      # header row: total,ssid
	{
		sub(/\r$/, "")                    # tolerate CRLF
		c = index($0, ",")
		if (c < 2) next
		total = substr($0, 1, c - 1)
		ssid  = substr($0, c + 1)
		if (ssid == "" || total !~ /^[0-9]+$/) next

		hex = ""
		L = length(ssid)
		for (j = 1; j <= L; j++) hex = hex sprintf("%02x", ord[substr(ssid, j, 1)])

		if (n % BATCH == 0) {
			if (n > 0) print ";"
			printf "insert ignore into ssid_freq (ssid_hex,total) values "
		} else {
			printf ","
		}
		printf "(\"%s\",%s)", hex, total
		n++
	}
	END { if (n > 0) print ";" }
	' lists/ssid.csv | mysql probeprint

	echo "ssid_freq now holds $(mysql -N probeprint <<< "select count(*) from ssid_freq;") rows"
}

# score_rarity [--recompute]
#
# Fill ssid_intel.ssid_total and ssid_intel.rarity. Incremental by default,
# matching the other enrichment passes, so re-running is cheap.
score_rarity () {
	local guard="and si.rarity is null"
	local guard2="and rarity is null"
	if [ "${1:-}" = "--recompute" ]; then
		guard=""
		guard2=""
	fi

	echo "score_rarity start $(date +"%H:%M:%S.%3N")"

	# One invocation: @corpus is a session variable and would not survive
	# being split across two calls to mysql.
	mysql probeprint <<SQL
set @corpus := (select sum(total) from ssid_freq);

update ssid_intel si
  join ssid_freq f on si.ssid_hex = f.ssid_hex
   set si.ssid_total = f.total,
       si.rarity     = ln(@corpus / f.total)
 where 1=1 $guard;

-- Not in the corpus at all: maximally rare. These are the personal, family and
-- workplace SSIDs that make a preferred-network list near-unique.
update ssid_intel
   set ssid_total = 0,
       rarity     = ln(@corpus)
 where ssid_hex <> '<MISSING>'
   and ssid_hex not like '%00%'
   and ssid_hex not like '%fff%'
   $guard2;
SQL

	echo "score_rarity stop $(date +"%H:%M:%S.%3N")"
}
