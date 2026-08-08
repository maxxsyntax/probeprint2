#!/bin/bash
# Language detection for Latin-script SSIDs, by vocabulary rather than script.
#
# check_language() in ssid_intel_functions.sh matches UTF-8 byte ranges, so it
# only ever sees Cyrillic, Arabic, Hebrew, Kana, Hangul, Greek and emoji. Every
# language written in Latin script is invisible to it. On a real collection that
# pass found 15 Kanji and 1 Greek in the whole corpus, while thousands of
# Spanish and German household names sat unclassified in OTHER_UNKNOWN.
#
# The two passes are complements, not alternatives: script detection handles
# non-Latin, this handles Latin. Neither replaces the other.
#
# --- Language is not a category ---------------------------------------------
#
# It is written to its own columns. "Familie Mueller" is a household AND German;
# forcing that into the single `category` column would lose one of the two. The
# pass does additionally set category=CULTURE_<LANG> when a row is still
# OTHER_UNKNOWN, matching the convention check_language() already established,
# but the authoritative answer is ssid_intel.lang.
#
# --- Precision over reach ---------------------------------------------------
#
# A false positive here invents a nationality for a real person, so the rules
# are deliberately strict:
#
#   * whole-token matching only. 'red' inside 'Redwood' is not Spanish.
#   * 'ambiguous' scope never decides on its own. Those words are also ordinary
#     English or shared across unrelated families.
#   * a 'family' scope match yields the family, never a guess at which member.
#   * conflicting single-language hits cancel rather than picking one.

# check_language_words [--recompute]
check_language_words () {
	local guard="and lang is null"
	[ "${1:-}" = "--recompute" ] && guard=""

	echo "check_language_words start $(date +"%H:%M:%S.%3N")"

	# word -> langs, and word -> scope
	local -A LW_LANG=() LW_SCOPE=()
	local w langs scope
	while IFS='|' read -r w langs scope; do
		case "$w" in ''|'#'*) continue ;; esac
		LW_LANG[${w,,}]=$langs
		LW_SCOPE[${w,,}]=$scope
	done < lists/lang_words.txt
	echo "  loaded ${#LW_LANG[@]} language markers"

	local ssid_hex ssid tok toks
	local hit_langs hit_scope decided decided_scope
	local n_lang=0 n_family=0 n_amb=0 n_conflict=0 n_none=0 batch=0

	local _sqlf; _sqlf=$(mktemp)
	{
		echo "start transaction;"
		while IFS='|' read -r ssid_hex ssid; do
			[ -z "$ssid_hex" ] && continue

			# Whole tokens only. Splitting on non-letters means 'Redwood' never
			# yields the token 'red'.
			toks=$(printf '%s' "${ssid,,}" | tr -c 'a-z0-9\xc0-\xff' '\n')

			decided=""; decided_scope=""; hit_langs=""; hit_scope=""
			local conflict=0 amb_only=0

			while IFS= read -r tok; do
				[ -z "$tok" ] && continue
				langs=${LW_LANG[$tok]:-}
				[ -z "$langs" ] && continue
				scope=${LW_SCOPE[$tok]:-}

				case "$scope" in
					ambiguous)
						amb_only=1
						[ -z "$hit_langs" ] && { hit_langs=$langs; hit_scope=ambiguous; }
						;;
					language)
						if [ -z "$decided" ]; then
							decided=$langs; decided_scope=language
						elif [ "$decided" != "$langs" ]; then
							# Two different single-language markers in one name.
							# Rather than pick, refuse.
							conflict=1
						fi
						;;
					family)
						# A family match only fills in if nothing stronger has.
						if [ -z "$decided" ]; then
							decided=$langs; decided_scope=family
						fi
						;;
				esac
			done <<< "$toks"

			if [ "$conflict" = "1" ]; then
				n_conflict=$((n_conflict+1)); continue
			fi

			if [ -z "$decided" ]; then
				if [ "$amb_only" = "1" ]; then
					# Recorded so the evidence is not lost, but scope says it is
					# not enough to act on.
					printf 'update ssid_intel set lang="%s", lang_scope="ambiguous" where ssid_hex="%s";\n' \
						"$hit_langs" "$ssid_hex"
					n_amb=$((n_amb+1)); batch=$((batch+1))
				else
					n_none=$((n_none+1))
				fi
				continue
			fi

			printf 'update ssid_intel set lang="%s", lang_scope="%s" where ssid_hex="%s";\n' \
				"$decided" "$decided_scope" "$ssid_hex"

			# Also clear it out of OTHER_UNKNOWN, following the CULTURE_*
			# convention check_language() already uses. Only a single-language
			# match is confident enough to name a culture.
			if [ "$decided_scope" = "language" ]; then
				printf 'update ssid_intel set category=concat("CULTURE_", upper("%s")) where ssid_hex="%s" and category="OTHER_UNKNOWN";\n' \
					"$decided" "$ssid_hex"
				n_lang=$((n_lang+1))
			else
				n_family=$((n_family+1))
			fi

			batch=$((batch+1))
			[ $((batch % 500)) -eq 0 ] && { echo "commit;"; echo "start transaction;"; }
		done <<< "$(mysql -N probeprint <<< "
			select concat_ws('|', ssid_hex,
			                 replace(replace(unhex(ssid_hex), '\n', ' '), '\r', ' '))
			  from ssid_intel
			 where ssid_hex not like '%00%'
			   and ssid_hex not like '%fff%'
			   $guard;")"
		echo "commit;"
	} > "$_sqlf"
	mysql probeprint < "$_sqlf"
	rm -f "$_sqlf"

	echo "  single language identified : $n_lang"
	echo "  language family only       : $n_family"
	echo "  ambiguous evidence only    : $n_amb"
	echo "  conflicting markers, refused: $n_conflict"
	echo "  no marker found            : $n_none"
	echo "check_language_words stop $(date +"%H:%M:%S.%3N")"
}

# language_report
language_report () {
	echo "=== languages identified from vocabulary (Latin script) ==="
	printf '  %-14s %-10s %7s\n' "language(s)" "scope" "ssids"
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "  %-14s %-10s %7s\n", $1, $2, $3 }'
select lang, lang_scope, count(*)
  from ssid_intel
 where lang is not null
 group by lang, lang_scope
 order by (lang_scope='language') desc, count(*) desc
 limit 30;
SQL
	echo
	echo "=== for comparison, what script detection alone found ==="
	mysql -N probeprint <<'SQL' | awk -F'\t' '{ printf "  %-24s %7s\n", $1, $2 }'
select category, count(*)
  from ssid_intel
 where category like 'CULTURE_%'
 group by category order by count(*) desc limit 20;
SQL
}
