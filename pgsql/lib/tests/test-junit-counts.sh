#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/junit-counts.py with fixture JUnit files. Needs python3 and jq.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/junit"
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

OUT=$(python3 -I "${LIB}/junit-counts.py" "${FIX}/mixed"); RC=$?
WANT='{"total":9,"failures":3,"errors":1,"skipped":2,"files":2,"files_unreadable":1}'
[[ ${RC} -eq 0 && $(jq -cS . <<< "${OUT}") == $(jq -cS . <<< "${WANT}") ]] \
    && pass "sums testsuite and testsuites files, counts the truncated file as unreadable" || fail "mixed (rc=${RC}: ${OUT})"

OUT=$(python3 -I "${LIB}/junit-counts.py" "${FIX}/badattr"); RC=$?
WANT='{"total":2,"failures":1,"errors":0,"skipped":0,"files":1,"files_unreadable":1}'
[[ ${RC} -eq 0 && $(jq -cS . <<< "${OUT}") == $(jq -cS . <<< "${WANT}") ]] \
    && pass "a file with a non-numeric count is unreadable, not a crash" || fail "badattr (rc=${RC}: ${OUT})"

OUT=$(python3 -I "${LIB}/junit-counts.py" "${FIX}/empty"); RC=$?
[[ ${RC} -eq 0 && ${OUT} == null ]] && pass "no XML gives null" || fail "empty (rc=${RC}: ${OUT})"

OUT=$(python3 -I "${LIB}/junit-counts.py" "${FIX}/no-such-dir"); RC=$?
[[ ${RC} -eq 0 && ${OUT} == null ]] && pass "missing directory gives null" || fail "missing dir (rc=${RC}: ${OUT})"

exit "${FAILED}"
