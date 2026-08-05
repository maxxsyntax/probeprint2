#!/bin/bash
# Run every probeprint2 test case. Exits non-zero if any case fails.
#
# Usage:
#   run_tests.sh              run all cases
#   run_tests.sh ingest       run only cases whose filename matches 'ingest'
set -uo pipefail

REPO=${REPO:-/opt/probeprint2}
export REPO
cd "$REPO"

FILTER=${1:-}
TOTAL=0
FAILED=0
FAILED_NAMES=()

echo
echo "======================================================================"
echo " probeprint2 test suite"
echo "======================================================================"

for case_file in "$REPO"/test/cases/*.sh; do
    [ -f "$case_file" ] || continue
    name=$(basename "$case_file" .sh)

    if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))
    echo
    echo "[$name]"

    # Each case runs in its own bash process so an `exit 1` in one case cannot
    # abort the whole run, and so a leaked IFS or cd cannot affect the next case.
    if bash "$case_file"; then
        :
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
done

echo
echo "======================================================================"
if [ "$FAILED" -eq 0 ]; then
    printf ' \033[32mALL %d CASES PASSED\033[0m\n' "$TOTAL"
    echo "======================================================================"
    exit 0
fi

printf ' \033[31m%d of %d CASES FAILED\033[0m\n' "$FAILED" "$TOTAL"
for n in "${FAILED_NAMES[@]}"; do
    echo "   - $n"
done
echo "======================================================================"
exit 1
