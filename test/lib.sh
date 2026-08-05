#!/bin/bash
# Shared assertion helpers for the probeprint2 test cases.
#
# Sourced by every file in test/cases/. Each case is a plain bash script that
# calls assert_* and exits non-zero if anything failed.

REPO=${REPO:-/opt/probeprint2}
FAILURES=0
CHECKS=0

_red()   { printf '\033[31m%s\033[0m' "$1"; }
_green() { printf '\033[32m%s\033[0m' "$1"; }

pass() {
    CHECKS=$((CHECKS + 1))
    printf '    %s %s\n' "$(_green PASS)" "$1"
}

fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf '    %s %s\n' "$(_red FAIL)" "$1"
    [ -n "${2:-}" ] && printf '         expected: %s\n' "$2"
    [ -n "${3:-}" ] && printf '         actual:   %s\n' "$3"
    return 0
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "$2" "$3"
    fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *)      fail "$1" "contains '$2'" "$3" ;;
    esac
}

# assert_not_contains <description> <needle> <haystack>
assert_not_contains() {
    case "$3" in
        *"$2"*) fail "$1" "does NOT contain '$2'" "$3" ;;
        *)      pass "$1" ;;
    esac
}

# sq <sql> -- run a query against probeprint, headerless, and trim whitespace.
sq() {
    mysql -N probeprint -e "$1" | tr -d '\r'
}

# sq1 <sql> -- single scalar result.
sq1() {
    sq "$1" | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# hexof <string> -- lowercase hex of a string, matching the ssid_hex convention.
hexof() {
    printf '%s' "$1" | xxd -p | tr -d '\n'
}

# reset_db -- drop all rows and reseed from fixtures/seed.sql. Each case starts
# from an identical database so cases cannot leak state into each other.
reset_db() {
    mysql probeprint -e "delete from ssid; delete from ssid_intel; delete from bursts;"
    mysql probeprint < "$REPO/test/fixtures/seed.sql"
}

# finish -- print the per-case tally and exit with the right status.
finish() {
    printf '    -- %d checks, %d failures\n' "$CHECKS" "$FAILURES"
    [ "$FAILURES" -eq 0 ] || exit 1
    exit 0
}
