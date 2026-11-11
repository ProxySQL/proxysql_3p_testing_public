#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/run-suite.sh with the minimal fixture suite: outcomes completed, timed_out,
# proxysql_crashed and no_results, test counts, metadata, and cleanup.
# Needs docker, jq, openssl, python3 and a local ProxySQL image in PROXYSQL_IMAGE.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${LIB}/tests/fixtures/suite-min"
if [[ -z ${PROXYSQL_IMAGE:-} ]] || ! docker image inspect "${PROXYSQL_IMAGE}" >/dev/null 2>&1; then
    echo "FAIL: set PROXYSQL_IMAGE to a local ProxySQL image (pgsql/README.md, 'Testing the scripts locally')"
    exit 1
fi
# shellcheck source=/dev/null
source "${LIB}/../versions.env"
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }
# shellcheck disable=SC2317  # called by the EXIT trap
cleanup() { docker run --rm -v "${TMP}:/t" --entrypoint rm "${POSTGRES_IMAGE}" -rf /t/w >/dev/null 2>&1; rm -rf "${TMP}"; }
trap cleanup EXIT
# containers of the legs run by this test only (other runs on the machine are ignored)
leftovers() {
    local f n=0
    for f in "${TMP}"/w/*/legs/*/compose.env; do
        [[ -f ${f} ]] || continue
        n=$(( n + $(docker ps -aq --filter "label=com.docker.compose.project=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "${f}")" | wc -l) ))
    done
    echo "${n}"
}

# run MODE LEG... -> W (work dir), RC, ELAPSED
run() {
    local mode=$1; shift
    W="${TMP}/w/${mode}"
    local t0=${SECONDS}
    FIXTURE_MODE=${mode} PGSQL3P_LEG_TIMEOUT_SECONDS=30 bash "${LIB}/run-suite.sh" "${SUITE}" "${W}" "$@" >"${W}.out" 2>&1; RC=$?
    ELAPSED=$(( SECONDS - t0 ))
}
leg() { jq -r "$2" "${W}/legs/$1/artifacts/leg.json" 2>/dev/null; }
mkdir -p "${TMP}/w"

run normal direct-plain proxy-plain
[[ ${RC} -eq 0 && $(leg direct-plain .status) == completed && $(leg proxy-plain .status) == completed \
    && $(leg direct-plain .tests.total) == 1 && $(leg proxy-plain .tests.failures) == 0 && $(leg proxy-plain .runner_exit_code) == 0 ]] \
    && pass "normal: both legs completed, 1 test, 0 failures" \
    || fail "normal: rc=${RC} $(leg direct-plain '{status,tests}' | tr -d '\n') $(leg proxy-plain '{status,tests}' | tr -d '\n') $(tail -n5 "${W}.out")"
[[ $(jq -r '.legs | length' "${W}/metadata.json" 2>/dev/null) == 2 && $(jq -r .suite "${W}/metadata.json") == suite-min \
    && $(jq -r '.runner.image_id' "${W}/metadata.json") == sha256:* ]] \
    && pass "normal: metadata.json lists the legs and the runner image" || fail "normal: metadata.json $(head -c 300 "${W}/metadata.json" 2>/dev/null)"
grep -q 'fixture: proxy-plain alice' "${W}/legs/proxy-plain/artifacts/test-output.log" 2>/dev/null \
    && pass "normal: runner output saved in test-output.log" || fail "normal: test-output.log"
[[ $(leftovers) -eq 0 ]] && pass "normal: nothing left behind" || fail "normal: leftovers $(leftovers)"

run sleep direct-plain proxy-plain
[[ $(leg direct-plain .status) == timed_out && $(leg direct-plain .tests.total) == 1 && ${ELAPSED} -lt 300 ]] \
    && pass "sleep: timed_out, results written before the hang kept" \
    || fail "sleep: $(leg direct-plain '{status,tests}' | tr -d '\n') after ${ELAPSED}s"
[[ $(leg proxy-plain .status) == timed_out ]] && pass "sleep: the next leg still ran after a timed-out leg (${ELAPSED}s in total)" \
    || fail "sleep: next leg $(leg proxy-plain '{status,reason}' | tr -d '\n')"
[[ $(leftovers) -eq 0 ]] && pass "sleep: the killed runner is removed" || fail "sleep: leftovers $(leftovers)"

run kill-proxysql proxy-plain
[[ $(leg proxy-plain .status) == proxysql_crashed && $(leg proxy-plain .tests.total) == 1 ]] \
    && pass "kill-proxysql: proxysql_crashed even though the runner wrote results" \
    || fail "kill-proxysql: $(leg proxy-plain '{status,tests,runner_exit_code}' | tr -d '\n')"

run no-xml direct-plain
[[ $(leg direct-plain .status) == no_results && $(leg direct-plain .tests) == null ]] \
    && pass "no-xml: no_results" || fail "no-xml: $(leg direct-plain '{status,tests}' | tr -d '\n')"

run bad-xml direct-plain
[[ $(leg direct-plain .status) == no_results && $(leg direct-plain .tests.files_unreadable) == 1 ]] \
    && pass "bad-xml: only unreadable JUnit is no_results, not completed" || fail "bad-xml: $(leg direct-plain '{status,tests}' | tr -d '\n')"

[[ $(find "${TMP}/w" -name leg.json -newer "${SUITE}/run.sh" -exec stat -c %U {} + | sort -u) == "$(id -un)" ]] \
    && pass "artifacts are owned by the calling user" || fail "artifact ownership: $(find "${TMP}/w" -path '*artifacts*' ! -user "$(id -un)" | head -3)"

exit "${FAILED}"
