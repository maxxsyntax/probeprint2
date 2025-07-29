check_language () {

        #https://www.loc.gov/marc/specifications/specchareacc/KoreanHangul.html
#       #'%e38[1,2,3]%' - japanese#

#sqlite3 new.db "update ssid_intel set category=CULTURE_LANGUAGE where category ssid_hex like 'e%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_JAPANESE' where (ssid_hex like '%e381%' or ssid_hex like '%e382%' or ssid_hex like '%e383%') and ssid_hex like 'e%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_KOREAN' where (ssid_hex like '%e384%' or ssid_hex like '%e385%' or ssid_hex like '%eab%'  or ssid_hex like '%eb8%'  or ssid_hex like 'ec%'  or ssid_hex like '%ead%') and ssid_hex like 'e%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_ARABIC' where ssid_hex like 'd98%' or ssid_hex like 'd89%' or ssid_hex like 'd8a%' or ssid_hex like 'd8b%' or ssid_hex like 'daa%' or ssid_hex like 'dab%' or ssid_hex like 'dbb%' ;"
mysql probeprint <<< "update ssid_intel set category='CULTURE_HEBREW' where ssid_hex like 'd6%' or ssid_hex like 'd7%' ;"
mysql probeprint <<< "update ssid_intel set category='CULTURE_CRYLIC' where ssid_hex like 'd1%' or ssid_hex like 'd0%' or ssid_hex like 'd2%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_KANJI' where ssid_hex like 'e4%' or ssid_hex like 'e5%' or ssid_hex like 'e6%' or ssid_hex like 'e7%' or ssid_hex like 'e8%' or ssid_hex like 'e9%';"
mysql probeprint <<< "update ssid_intel set category='CULTURE_GREEK' where ssid_hex like 'cc%' or ssid_hex like 'cd%' or ssid_hex like 'ce%'  or ssid_hex like 'cd%' or ssid_hex like 'ce%' or ssid_hex like 'cf%' ;"
mysql probeprint <<< "update ssid_intel set category='CULTURE_EMOJI' where ssid_hex like '%efb88f%' or ssid_hex like 'f09f%' or ssid_hex like 'e29%' ;"

}

check_language
