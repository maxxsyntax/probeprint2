#!/bin/bash
# check_name -- personal and family names in SSIDs.
check_name () {
echo check_name start $(date +"%H:%M:%S.%3N")

# --- explicit possessive and family markers -------------------------------
#
# Four SQL statements replacing four shell loops that each forked `sed`, `xxd`
# and `tr` per row and issued a `mysql` per match. substring_index and replace
# do the same cutting server-side.
#
# Possessive: keep whatever precedes the "'s", so "Adam's iPhone" -> Adam.
#
# Matched with a case-insensitive regexp, NOT a byte-exact hex LIKE. The old
# form only matched lowercase "'s " (hex 277320) with a trailing space, so
# "ADRIANA'S NETWORK" (uppercase S) went untagged, and so did any SSID ending
# in the possessive with no trailing word ("Adam's"). `(?i)'s( |$)` accepts
# either case and either a following space or end-of-string; regexp_replace then
# strips the "'s" and everything after it. Family markers below stay byte-exact
# -- they are whole words, not a two-character suffix, so case matters less and
# a literal replace is clearer.
#
# left(...,255) because is_name is a varchar and an over-long value would be
# truncated with a warning rather than rejected.
mysql probeprint <<'SQL'
update ssid_intel
   set is_name = left(trim(regexp_replace(unhex(ssid_hex), "(?i)'s( .*)?$", '')), 255)
 where unhex(ssid_hex) regexp "(?i)'s( |$)" and is_name is null;

update ssid_intel
   set is_name = left(trim(replace(unhex(ssid_hex), 'Familia ', '')), 255)
 where ssid_hex like '46616d696c6961%' and is_name is null;

update ssid_intel
   set is_name = left(trim(replace(unhex(ssid_hex), 'familia ', '')), 255)
 where ssid_hex like '66616d696c6961%' and is_name is null;

update ssid_intel
   set is_name = left(trim(replace(unhex(ssid_hex), 'Family', '')), 255)
 where ssid_hex like '%46616d696c79' and is_name is null;
SQL

# Whole-token name matching. The old form matched a name as a substring
# anywhere in the SSID (like "%name%"), so short names tagged unrelated
# networks: "Al" matched "Portal", "Alarm", "Balcony", and the fragment was
# written into is_name as though it were a person. A name now matches only as a
# complete token, delimited by a word boundary -- the start or end of the SSID,
# or a separator byte (space, -, _, .). Decode each SSID once, split it into
# tokens, and compare whole tokens against the name set.
#
# Two refinements make it match how people actually name devices:
#   - Capitalization is the signal that a token is a person's name rather than a
#     common word. A name token must start with an uppercase letter (Maria,
#     MARIA), so "guest", "home", "portal" are never read as names.
#   - A trailing possessive "s" without an apostrophe is stripped: "Marias
#     iPhone" -> Maria. The full token is checked first, so real names that end
#     in s (Chris, James) still match as themselves.
# lists/names.txt is Title Case; store it lowercased and compare case-insensitively.
local -A nameset=()
local nm
while read -r nm; do
	nm=${nm,,}
	# Skip 1-2 character names: too short to match without heavy noise.
	[ ${#nm} -ge 3 ] && nameset[$nm]=1
done < lists/names.txt

local ssid_hex ssid t tl match esc n=0
local -a toks
local _sqlf; _sqlf=$(mktemp)

# Decode in SQL and batch the writes. This forked `xxd` and `tr` per row and
# issued a separate `mysql` per match; on this host a `mysql` invocation costs
# 35ms against 0.82ms for the same statement in an already-open session, so the
# process spawn was the whole cost.
#
# --default-character-set=utf8mb4 for the same reason as the language pass:
# without it the client negotiates latin1 and the server transcodes, so an
# accented name arrives as different bytes than lists/names.txt holds.
#
# Newlines are flattened so the line-oriented read stays aligned, and rows whose
# hex contains a null byte are excluded -- bash drops NUL in command
# substitution, which would silently compare a different string.
{
	echo "start transaction;"
	while IFS='|' read -r ssid_hex ssid; do
		[ -z "$ssid_hex" ] && continue
		# IFS scoped to this read only, so it cannot leak into other functions.
		IFS=' -_.' read -r -a toks <<< "$ssid"
		for t in "${toks[@]}"; do
			# Require an uppercase initial: a name is a proper noun.
			[[ $t == [A-Z]* ]] || continue
			tl=${t,,}
			match=""
			if [[ -n ${nameset[$tl]:-} ]]; then
				match=$t                       # exact name; keep the SSID's casing
			elif [[ $tl == *s && -n ${nameset[${tl%s}]:-} ]]; then
				match=${t%[sS]}                # possessive: "Marias" -> "Maria"
			fi
			if [ -n "$match" ]; then
				# Double any single quote for the SQL string literal.
				esc=${match//\'/\'\'}
				printf 'update ssid_intel set is_name=%s where ssid_hex="%s";\n' \
					"'$esc'" "$ssid_hex"
				n=$((n+1))
				[ $((n % 500)) -eq 0 ] && { echo "commit;"; echo "start transaction;"; }
				break
			fi
		done
	done <<< "$(mysql -N --default-character-set=utf8mb4 probeprint <<< "
		select concat_ws('|', ssid_hex,
		                 replace(replace(unhex(ssid_hex), char(10), ' '), char(13), ' '))
		  from ssid_intel
		 where is_name is null
		   and ssid_hex not like '%00%';")"
	echo "commit;"
} > "$_sqlf"
mysql probeprint < "$_sqlf"
rm -f "$_sqlf"
echo "  names matched as a whole token: $n"
# `0` is this pass's "looked, found no name" sentinel, written by the line
# below. It is a string in a varchar column, so `is_name != ''` is TRUE for it
# -- which meant that on the SECOND and every later run, every row the pass had
# already rejected was categorized as NAME. One run looked correct; a re-run
# swallowed the corpus, and since the passes are meant to be re-run freely that
# is the normal state. Measured on a real collection it had taken 94% of all
# category=NAME rows.
#
# Also scoped to rows no other pass has decided. NAME is a weak classification
# and must not overwrite BIZ_EATERY or TECH_CPE, which are derived from stronger
# evidence than one capitalized token.
mysql probeprint <<< "update ssid_intel set category=\"NAME\"
                       where is_name is not null
                         and is_name not in ('', '0')
                         and (category is null or category = 'OTHER_UNKNOWN');"
mysql probeprint <<< "update ssid_intel set is_name=0 where is_name is null;"
echo check_name stop $(date +"%H:%M:%S.%3N")
}
