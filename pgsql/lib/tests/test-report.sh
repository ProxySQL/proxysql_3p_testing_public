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
unset GITHUB_RUN_ATTEMPT

BASE=$(scenario base)
report "${BASE}" demo
BASE_RC=${RC}
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

# --- comparison and labels: comparison.json
C=${BASE}/out/comparison.json
P='.suites.demo.legs["proxy-plain"]'
# cls JQ_LEG CLASS: the ids of one class of a leg, space-separated
cls() { jq -r "$1.classes.$2 | map(.id) | join(\" \")" "${C}" 2>/dev/null; }
[[ $(cls "$P" proxy_regression) == 'a.B::err(<T>) a.B::gone() a.B::run()#2' && $(cls "$P" both_fail) == 'a.B::broken() a.B::nomsg(a|b)' \
    && $(cls "$P" proxy_only_pass) == 'a.B::flaky()' && $(cls "$P" skip_mismatch) == 'a.B::skipme()' \
    && $(cls "$P" leg_only) == 'a.B::initializationError' && -z $(cls "$P" not_executed) && $(jq "$P.classes.not_executed" "${C}") == '[]' ]] \
    && pass "each difference lands in its class" || fail "classes (rc=${RC})"

[[ $(jq -r "$P.classes.proxy_regression | map(.outcome) | join(\" \")" "${C}" 2>/dev/null) == 'errored not_executed failed' ]] \
    && pass "a regression keeps the leg's outcome, or not_executed" || fail "regression outcomes"

[[ $(jq -c "$P.counts" "${C}" 2>/dev/null) == '{"errored":1,"failed":4,"passed":5,"skipped":0,"total":10}' \
    && $(jq -c "[$P.not_executed, $P.files_unreadable, $P.baseline, $P.comparable]" "${C}" 2>/dev/null) == '[1,1,"direct-plain",true]' \
    && $(jq -c '.suites.demo.legs["direct-plain"] | [.counts, .duration_s, .baseline, .classes]' "${C}" 2>/dev/null) \
        == '[{"errored":0,"failed":3,"passed":6,"skipped":1,"total":10},232,null,null]' ]] \
    && pass "counts, not executed, unreadable files and duration per leg" || fail "counts"

# reasons JQ_LEG CLASS ID: the reasons of one entry's labels, joined by ';'
reasons() { jq -r --arg id "$3" "$1.classes.$2[] | select(.id == \$id) | .labels | map(.reason) | join(\";\")" "${C}" 2>/dev/null; }
T='.suites.demo.legs["proxy-tls"]'
[[ $(reasons "$P" proxy_regression 'a.B::run()#2') == 'Users created by the test are unknown to ProxySQL' \
    && $(reasons "$P" both_fail 'a.B::broken()') == 'The runner runs as root' \
    && $(reasons "$T" proxy_regression 'a.B::tls()') == 'TLS ends at ProxySQL' && -z $(reasons "$T" proxy_regression 'a.B::tls()#2') \
    && $(jq -r "$T.classes.proxy_regression[] | select(.id == \"a.B::tls()#3\") | .outcome" "${C}" 2>/dev/null) == not_executed ]] \
    && pass "labels match by test id glob (with #n) and by failure message" || fail "labels"

[[ $(jq -r '.suites.demo.legs["direct-plain"].baseline_failures | map(.id + "=" + (.labels | length | tostring)) | join(" ")' "${C}" 2>/dev/null) \
    == 'a.B::broken()=1 a.B::flaky()=0 a.B::nomsg(a|b)=0' ]] \
    && pass "direct legs list their failures, with labels" || fail "baseline failures"

NOL=$(scenario nolabels)
rm "${NOL}/suites/demo/known-issues.toml"
report "${NOL}" demo
[[ ${RC} -eq 0 && $(jq -cS '.suites.demo.legs | del(..|.labels?)' "${C}") == "$(jq -cS '.suites.demo.legs | del(..|.labels?)' "${NOL}/out/comparison.json")" \
    && $(jq '[.. | .labels? // empty | length] | add' "${NOL}/out/comparison.json") == 0 ]] \
    && pass "labels never change counts or classes; no known-issues.toml means no labels" || fail "labels change results (rc=${RC})"

GOOD=$'label = "config"\nreason = "r"\ntests = ["a.B::x()"]'
for bad in $'[[issue]]\nlabel = "nope"\nreason = "r"\ntests = ["a.B::x()"]' \
           $'[[issue]]\nlabel = "config"\nreason = ""\ntests = ["a.B::x()"]' \
           $'[[issue]]\n'"${GOOD}"$'\nmessage = "("' \
           $'[[issue]]\n'"${GOOD}"$'\nmesage = "client certificate"' \
           'issue = ["x"]' \
           $'[[issues]]\n'"${GOOD}"; do
    BAD=$(scenario bad)
    echo "${bad}" > "${BAD}/suites/demo/known-issues.toml"
    report "${BAD}" demo
    WHAT=$(head -c 40 <<< "${bad//$'\n'/ }")
    [[ ${RC} -eq 2 && $(< "${BAD}/stderr") == *known-issues.toml* && $(< "${BAD}/stderr") != *Traceback* ]] \
        && pass "a broken known-issues.toml exits 2 naming the file: ${WHAT}" || fail "bad issue ${WHAT} (rc=${RC}: $(< "${BAD}/stderr"))"
    [[ ${bad} != '[[issue]]'* || $(< "${BAD}/stderr") == *"issue 1"* ]] || fail "bad issue ${WHAT}: entry not named"
    rm -rf "${BAD}"
done

# --- report.md, report.html, red / green
MD=${BASE}/out/report.md HTML=${BASE}/out/report.html
# has FILE TEXT...: FILE contains every TEXT as a fixed string
has() { local f=$1; shift; for t in "$@"; do grep -qF -- "${t}" "${f}" 2>/dev/null || { echo "  missing in ${f##*/}: ${t}"; return 1; }; done; }
[[ ${BASE_RC} -eq 0 ]] && has "${MD}" '# PostgreSQL 3rd-party tests: report' '**Result: green**' \
    '| Leg | Status | Compared with | Total | Passed | Failed | Errored | Skipped | Not executed | Regressions | Duration |' \
    '| proxy-plain | completed | direct-plain | 10 | 5 | 4 | 1 | 0 | 1 | 3 | 3m 52s |' \
    '| direct-tls | completed | - | 4 | 4 | 0 | 0 | 0 | - | - | 1h 02m |' \
    '### proxy-plain: 3 tests pass directly but not through ProxySQL' \
    '| Class | Failed | Errored | Not executed | Labels |' \
    'Not reached before the time limit: 1 (of 1 not executed)' \
    '| proxy-tls | timed_out | direct-tls | 3 | 1 | 2 | 0 | 0 | 1 | 2 | 1h 00m |' \
    '### proxy-tls: 2 tests pass directly but not through ProxySQL' \
    'Results from pgsql-3p-demo-abcdef1-r1-a1.' \
    'Fails both ways: 2 · passes only through ProxySQL: 1 · skipped in one leg only: 1 · only in this leg: 1' \
    'direct-plain: a.B::flaky() (failed): unexplained' \
    'direct-plain: a.B::broken() (failed): environment: The runner runs as root' \
    'No comparison with earlier runs yet.' 'proxy-plain: 1 JUnit files could not be read.' \
    && pass "green report: leg table, regressions by class, not reached, baseline failures, history hook" || fail "green report (rc=${BASE_RC})"

[[ $(jq .red "${C}") == false ]] && has "${MD}" '| a.B | 1 | 1 | 1 | proxy-architecture (1) |' \
    && pass "a regression class row counts failed, errored and not executed, and its labels" || fail "class row"

has "${MD}" 'direct-plain: a.B::nomsg(a\|b) (failed): unexplained' && ! grep -qF 'err(<T>)' "${MD}" \
    && has "${HTML}" 'a.B::err(&lt;T&gt;)' && ! grep -qF 'err(<T>)' "${HTML}" \
    && pass "test names are escaped in report.md and report.html" || fail "escaping"

[[ $(head -c 15 "${HTML}") == '<!doctype html>' ]] && ! grep -qiE '<script|<link|src=' "${HTML}" \
    && has "${HTML}" 'Not reached before the time limit: 1 (of 1 not executed)' 'class setup failed' \
    && pass "report.html is self-contained and lists the details" || fail "html"

# setleg DIR LEG STATUS [REASON]
setleg() {
    local f=$1/${A}/legs/$2/leg.json
    jq --arg s "$3" --arg r "${4:-}" '.status = $s | .reason = $r' "${f}" > "${f}.new" && mv "${f}.new" "${f}"
}
# red NAME PROBLEM [SUITE...]: the scenario NAME (already changed) is red with PROBLEM
red() {
    local name=$1 problem=$2; shift 2
    report "${TMP}/${name}" "${@:-demo}"
    [[ ${RC} -eq 1 && $(jq .red "${TMP}/${name}/out/comparison.json") == true ]] \
        && has "${TMP}/${name}/out/report.md" '**Result: red**' "${problem}" && grep -qF "::error::${problem}" "${TMP}/${name}/stderr" \
        && pass "red: ${problem}" || fail "red ${name} (rc=${RC}: $(< "${TMP}/${name}/stderr"))"
}
setleg "$(scenario crashed)" proxy-plain proxysql_crashed;          red crashed 'demo proxy-plain: proxysql_crashed'
setleg "$(scenario infra)" proxy-tls infra_failure 'start proxysql: x'; red infra 'demo proxy-tls: infra_failure: start proxysql: x'
setleg "$(scenario noresults)" proxy-plain no_results;              red noresults 'demo proxy-plain: no_results'
setleg "$(scenario ready)" proxy-tls ready;                         red ready 'demo proxy-tls: ready'
has "${TMP}/crashed/out/report.md" '| proxy-plain | proxysql_crashed | direct-plain |' '### proxy-plain: 3 tests pass directly but not through ProxySQL' \
    && has "${TMP}/infra/out/report.md" '| proxy-tls | infra_failure | direct-tls (not run) |' \
    && pass "a leg that crashed is still compared; a leg that could not be set up is not run" || fail "crashed/infra comparison"
setleg "$(scenario baseline)" direct-tls timed_out;                 red baseline 'demo proxy-tls: not comparable, baseline direct-tls is timed_out'
has "${TMP}/baseline/out/report.md" '| proxy-tls | timed_out | direct-tls (not comparable) |' \
    && pass "a proxy leg without a completed baseline is shown as not comparable" || fail "not comparable row"
scenario missing > /dev/null;                                       red missing 'other: no results uploaded' demo other
has "${TMP}/missing/out/report.md" '## demo' '## other' && pass "the other suites are still reported" || fail "missing: demo not reported"
NS=$(scenario nostart); echo '{"reason": "fetching x failed"}' > "${NS}/${A}/suite-status.json"
red nostart 'demo: could not start: fetching x failed'

# I1: in a leg that stopped early, only tests of classes it never started, or after the last test it
# ran of a class, count as not reached; a class that failed as a whole shows in the table
CF=$(scenario classfail)
printf '<testsuite name="c.D"><testcase name="x()" classname="c.D"/><testcase name="y()" classname="c.D"/></testsuite>\n' \
    > "${CF}/${A}/legs/direct-tls/junit/TEST-c.D.xml"
printf '<testsuite name="e.F"><testcase name="z()" classname="e.F"/></testsuite>\n' > "${CF}/${A}/legs/direct-tls/junit/TEST-e.F.xml"
printf '<testsuite name="c.D"><testcase name="initializationError" classname="c.D"><failure message="no"/></testcase></testsuite>\n' \
    > "${CF}/${A}/legs/proxy-tls/junit/PARTIAL-c.D.xml"
report "${CF}" demo
has "${CF}/out/report.md" '| c.D | 0 | 0 | 2 |  |' 'Not reached before the time limit: 2 (of 4 not executed)' \
    && pass "a class that failed as a whole in a stopped leg is listed, not counted as not reached" || fail "class failure in a stopped leg"

# I4: the report says which artifact it used, and when it is from an earlier attempt
ATT2=$(scenario attempt2)
GITHUB_RUN_ATTEMPT=2 report "${ATT2}" demo
has "${ATT2}/out/report.md" 'Results from pgsql-3p-demo-abcdef1-r1-a1. These results are from attempt 1; this is attempt 2.' \
    && pass "results of an earlier attempt are named as such" || fail "earlier attempt"

# I5: long lists in report.md stop after 100 lines (the run page summary must stay under 1 MB)
LONGL=$(scenario long)
{ echo '<testsuite name="g.H">'
  for i in $(seq 150); do echo "<testcase name=\"t${i}()\" classname=\"g.H\"><failure message=\"m\"/></testcase>"; done
  echo '</testsuite>'; } > "${LONGL}/${A}/legs/direct-plain/junit/TEST-g.H.xml"
report "${LONGL}" demo
[[ $(grep -c '^- direct-plain: ' "${LONGL}/out/report.md") -eq 100 ]] && has "${LONGL}/out/report.md" 'And 53 more in report.html.' \
    && pass "report.md lists at most 100 baseline failures" || fail "long list ($(grep -c '^- direct-plain:' "${LONGL}/out/report.md"))"

ERR=$(python3 -I "${LIB}/report.py" only-two-args x 2>&1 > /dev/null); RC=$?
[[ ${RC} -eq 2 && ${ERR} == *"usage: report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE..."* ]] \
    && pass "wrong arguments exit 2 with the usage" || fail "usage (rc=${RC}: ${ERR})"

exit "${FAILED}"
