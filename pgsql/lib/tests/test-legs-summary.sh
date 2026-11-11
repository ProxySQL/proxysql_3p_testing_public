#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/legs-summary.sh with hand-made leg.json files. Needs jq.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

mk() {  # mk LEG STATUS REASON [TESTS_JSON]
    mkdir -p "${TMP}/legs/$1/artifacts"
    jq -n --arg leg "$1" --arg s "$2" --arg r "$3" --argjson t "${4:-null}" '{leg: $leg, status: $s, reason: $r,
        server_version: "18.6", backend_protocol: null, proxysql_config_sha256: null, tests: $t}' \
        > "${TMP}/legs/$1/artifacts/leg.json"
}
mk direct-plain completed "" '{"total":10,"failures":2,"errors":1,"skipped":3,"files":4,"files_unreadable":0}'
mk direct-tls ready ""
mk proxy-tls timed_out "" '{"total":4,"failures":0,"errors":0,"skipped":0,"files":1,"files_unreadable":0}'
mk proxy-plain infra_failure $'prove connection and tls: connection failed:\npsql: error | timeout expired'

OUT=$(bash "${LIB}/legs-summary.sh" "${TMP}/legs" direct-plain direct-tls proxy-tls proxy-plain no-leg-json 2>"${TMP}/err"); RC=$?
ROWS=$(grep -c '^|' <<< "${OUT}")
[[ ${ROWS} -eq 7 ]] && pass "one table row per leg, plus header and separator" || fail "rows=${ROWS}: ${OUT}"
grep -q '^| direct-plain | completed | 10 | 2 | 1 | 3 |  |' <<< "${OUT}" \
    && pass "test counts: total, failed, errors, skipped" || fail "counts row: ${OUT}"
grep -q '^| direct-tls | ready | - | - | - | - |  |' <<< "${OUT}" && pass "no test counts shown as -" || fail "no counts row: ${OUT}"
grep -q '^| proxy-plain | infra_failure | - | - | - | - | prove connection and tls: connection failed: psql: error \\| timeout expired |' <<< "${OUT}" \
    && pass "multi-line reason is flattened and '|' escaped" || fail "reason row: ${OUT}"
grep -q '^| no-leg-json | no leg.json |' <<< "${OUT}" && pass "a leg without leg.json is reported" || fail "missing leg.json row"
[[ ${RC} -eq 1 && $(cat "${TMP}/err") == *"proxy-plain"* && $(cat "${TMP}/err") == *"no-leg-json"* \
    && $(cat "${TMP}/err") != *"proxy-tls"* && $(cat "${TMP}/err") != *"direct-plain"* ]] \
    && pass "exit 1 naming only the legs whose setup failed (not test outcomes)" || fail "rc=${RC} err=$(cat "${TMP}/err")"

bash "${LIB}/legs-summary.sh" "${TMP}/legs" direct-plain direct-tls proxy-tls >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 0 ]] && pass "exit 0 when no leg failed its setup (completed, timed_out, ready)" || fail "rc=${RC}"

exit "${FAILED}"
