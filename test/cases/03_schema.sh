#!/bin/bash
# Schema bootstrap: build_dbs.sh must run clean and create everything.
#
# It previously ended with two bare SQL statements outside any mysql
# invocation, so bash tried to execute `create` as a shell command and the
# 'pi' user the distributed nodes connect as was never created.
source "${REPO:-/opt/probeprint2}/test/lib.sh"
cd "$REPO"

# Re-running must be idempotent -- the entrypoint already ran it once.
./build_dbs.sh >/tmp/build_dbs.log 2>&1
rc=$?

assert_eq "build_dbs.sh exits 0 on a re-run" "0" "$rc"

assert_not_contains "no 'command not found' from bare SQL" \
    "command not found" "$(cat /tmp/build_dbs.log)"
assert_not_contains "no SQL errors" \
    "ERROR" "$(cat /tmp/build_dbs.log)"

# --- tables --------------------------------------------------------------
for t in ssid ssid_intel bursts; do
    assert_eq "table $t exists" "1" \
        "$(sq1 "select count(*) from information_schema.tables where table_schema='probeprint' and table_name='$t';")"
done

# --- the score column score()/bump_score() write to ----------------------
assert_eq "ssid_intel.score column exists" "1" \
    "$(sq1 "select count(*) from information_schema.columns where table_schema='probeprint' and table_name='ssid_intel' and column_name='score';")"

# --- the 'pi' user the client/ nodes authenticate as --------------------
assert_eq "mysql user 'pi' was created" "1" \
    "$(sq1 "select count(*) from mysql.user where user='pi';")"

finish
