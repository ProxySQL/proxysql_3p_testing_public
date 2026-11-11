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

mk() {  # mk LEG STATUS REASON
    mkdir -p "${TMP}/legs/$1/artifacts"
    jq -n --arg leg "$1" --arg s "$2" --arg r "$3" '{leg: $leg, status: $s, reason: $r, server_version: "18.6",
        backend_protocol: null, proxysql_config_sha256: null}' > "${TMP}/legs/$1/artifacts/leg.json"
}
mk direct-plain ready ""
mk proxy-plain infra_failure $'prove connection and tls: connection failed:\npsql: error | timeout expired'

OUT=$(bash "${LIB}/legs-summary.sh" "${TMP}/legs" direct-plain proxy-plain no-leg-json 2>"${TMP}/err"); RC=$?
ROWS=$(grep -c '^|' <<< "${OUT}")
[[ ${ROWS} -eq 5 ]] && pass "one table row per leg, plus header and separator" || fail "rows=${ROWS}: ${OUT}"
grep -q '^| proxy-plain | infra_failure | prove connection and tls: connection failed: psql: error \\| timeout expired |' <<< "${OUT}" \
    && pass "multi-line reason is flattened and '|' escaped" || fail "reason row: ${OUT}"
grep -q '^| no-leg-json | no leg.json |' <<< "${OUT}" && pass "a leg without leg.json is reported" || fail "missing leg.json row"
[[ ${RC} -eq 1 && $(cat "${TMP}/err") == *"proxy-plain"* && $(cat "${TMP}/err") == *"no-leg-json"* ]] \
    && pass "exit 1 naming the legs that are not ready" || fail "rc=${RC} err=$(cat "${TMP}/err")"

OUT=$(bash "${LIB}/legs-summary.sh" "${TMP}/legs" direct-plain 2>/dev/null); RC=$?
[[ ${RC} -eq 0 ]] && pass "exit 0 when every leg is ready" || fail "all ready rc=${RC}"

exit "${FAILED}"
