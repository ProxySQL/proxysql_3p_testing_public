#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/fetch-suite.sh against a local repository with a tag (no network).
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

UP="${TMP}/upstream"
git -C "${TMP}" init -q -b main upstream
echo tests > "${UP}/tests.txt"
git -C "${UP}" add tests.txt
git -C "${UP}" -c user.name=t -c user.email=t@t commit -q -m tests
git -C "${UP}" tag v1
SHA=$(git -C "${UP}" rev-parse HEAD)
OTHER=0123456789abcdef0123456789abcdef01234567

suite() {  # suite DIR SHA [omit-key]
    mkdir -p "$1"
    {
        echo "UPSTREAM_REPO=${UP}"
        [[ ${3:-} == ref ]] || echo "UPSTREAM_REF=v1"
        echo "UPSTREAM_SHA=$2"
    } > "$1/suite.env"
}

suite "${TMP}/ok" "${SHA}"
OUT=$(bash "${LIB}/fetch-suite.sh" "${TMP}/ok" "${TMP}/dest-ok" 2>/dev/null); RC=$?
[[ ${RC} -eq 0 && ${OUT} == "${SHA}" && -f ${TMP}/dest-ok/tests.txt ]] \
    && pass "pinned tag at the expected commit is fetched" || fail "ok (rc=${RC}, out='${OUT}')"

suite "${TMP}/moved" "${OTHER}"
ERR=$(bash "${LIB}/fetch-suite.sh" "${TMP}/moved" "${TMP}/dest-moved" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && ${ERR} == *"${SHA}"* && ${ERR} == *"${OTHER}"* ]] \
    && pass "tag pointing to another commit fails, naming both commits" || fail "moved tag (rc=${RC}, err='${ERR}')"

suite "${TMP}/noref" "${SHA}" ref
bash "${LIB}/fetch-suite.sh" "${TMP}/noref" "${TMP}/dest-noref" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 1 ]] && pass "missing UPSTREAM_REF fails" || fail "missing key (rc=${RC})"

mkdir -p "${TMP}/exists"
bash "${LIB}/fetch-suite.sh" "${TMP}/ok" "${TMP}/exists" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 1 ]] && pass "existing destination fails" || fail "existing dest (rc=${RC})"

exit "${FAILED}"
