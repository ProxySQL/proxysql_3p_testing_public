#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/report.py with the fixture artifacts in fixtures/report. Needs python3 and jq.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/report"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# scenario NAME: a copy of the fixture to change; prints its folder
scenario() { mkdir -p "${TMP}/$1" && cp -r "${FIX}/suites" "${FIX}/downloads" "${TMP}/$1/" && echo "${TMP}/$1"; }
# report DIR SUITE...: runs report.py on DIR's suites and downloads into DIR/out; sets RC
report() {
    local dir=$1; shift
    python3 -I "${LIB}/report.py" "${dir}/suites" "${dir}/downloads" "${dir}/out" "$@" > "${dir}/stdout" 2> "${dir}/stderr"
    RC=$?
}
A=downloads/pgsql-3p-demo-abcdef1-r1-a1

BASE=$(scenario base)
report "${BASE}" demo
R=${BASE}/out/demo
# ids DIR LEG: the leg's test ids, one per line
ids() { jq -r '.tests | keys[]' "$1/$2/results.json" 2>/dev/null; }
outcome() { jq -r --arg id "$3" '.tests[$id].outcome' "$1/$2/results.json" 2>/dev/null; }
msg() { jq -r --arg id "$3" '.tests[$id].message // "NONE"' "$1/$2/results.json" 2>/dev/null; }

# --- normalizing: results.json per leg
IDS=$(ids "${R}" direct-plain)
grep -qxF 'a.B::run()' <<< "${IDS}" && grep -qxF 'a.B::run()#2' <<< "${IDS}" && grep -qxF 'a.B::run()#3' <<< "${IDS}" \
    && ! grep -qxF 'a.B::run()#1' <<< "${IDS}" && pass "repeated names get #n from the second one on" || fail "repeats (rc=${RC}: ${IDS})"

[[ $(outcome "${R}" proxy-plain 'a.B::run()#2') == failed && $(outcome "${R}" proxy-plain 'a.B::err(<T>)') == errored \
    && $(outcome "${R}" proxy-plain 'a.B::skipme()') == passed && $(outcome "${R}" direct-plain 'a.B::skipme()') == skipped ]] \
    && pass "failure, error, skipped and passed outcomes" || fail "outcomes"

[[ $(msg "${R}" direct-plain 'a.B::broken()') == 'root owns it' && $(msg "${R}" direct-plain 'a.B::flaky()' | tr -d '\n' | wc -c) -eq 300 \
    && $(msg "${R}" direct-plain 'a.B::nomsg(a|b)') == 'first text line' && $(msg "${R}" direct-plain 'a.B::ok()') == NONE ]] \
    && pass "message: first line of the attribute or text, at most 300 characters, none for a passed test" || fail "messages"

! ids "${R}" proxy-plain | grep -qF 'ignored()' && [[ $(jq -c '[.files, .files_unreadable]' "${R}/proxy-plain/results.json" 2>/dev/null) == '[1,1]' ]] \
    && pass "PARTIAL files are ignored next to TEST files; a cut-off file is unreadable" || fail "partial ignored / unreadable"

[[ $(ids "${R}" proxy-tls | tr '\n' ' ') == 'a.B::ok() a.B::tls() a.B::tls()#2 ' && $(jq .files "${R}/proxy-tls/results.json" 2>/dev/null) == 1 ]] \
    && pass "PARTIAL files are read when there is no TEST file" || fail "partial alone"

ATT=$(scenario attempt)
cp -r "${ATT}/${A}" "${ATT}/downloads/pgsql-3p-demo-abcdef1-r1-a2"
printf '<testsuite name="a.B"><testcase name="ok()" classname="a.B"/></testsuite>\n' \
    > "${ATT}/downloads/pgsql-3p-demo-abcdef1-r1-a2/legs/direct-plain/junit/TEST-a.B.xml"
report "${ATT}" demo
[[ $(ids "${ATT}/out/demo" direct-plain | wc -l) -eq 1 ]] && pass "the newest attempt's artifact is used" || fail "attempt (rc=${RC})"

ERR=$(python3 -I "${LIB}/report.py" only-two-args x 2>&1 > /dev/null); RC=$?
[[ ${RC} -eq 2 && ${ERR} == *"usage: report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE..."* ]] \
    && pass "wrong arguments exit 2 with the usage" || fail "usage (rc=${RC}: ${ERR})"

exit "${FAILED}"
