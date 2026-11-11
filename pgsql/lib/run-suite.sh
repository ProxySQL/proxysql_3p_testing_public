#!/usr/bin/env bash
# Usage: run-suite.sh SUITE WORK_DIR LEG...
#   SUITE: a folder name under pgsql/suites/, or a path to a suite folder
#   env:   PROXYSQL_IMAGE (proxy legs); optional PROXYSQL_SHA, PROXYSQL_VERSION, PROXYSQL_IMAGE_ID (metadata)
# Runs one suite in each LEG, one after the other:
#   once:    fetch the upstream tests (fetch-suite.sh), certificates (the suite's prepare.sh, else
#            certs.sh), build the suite's runner image
#   per leg: leg-up.sh in suite mode, the runner with the suite's time limit, the outcome, the JUnit
#            counts, leg-down.sh
# Each leg's WORK_DIR/legs/<leg>/artifacts/leg.json gets status completed | timed_out | no_results |
# proxysql_crashed (or infra_failure from leg-up.sh), runner_exit_code and tests. WORK_DIR/metadata.json
# describes the run. Exit 1 if the suite could not start (WORK_DIR/suite-status.json says why) or a leg
# is infra_failure; test failures do not change the exit code.
# Tests only: PGSQL3P_UPSTREAM_DIR (use this checkout instead of fetching), PGSQL3P_LEG_TIMEOUT_SECONDS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../versions.env
source "${HERE}/../versions.env"

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -ge 3 ]] || die "usage: run-suite.sh SUITE WORK_DIR LEG..."
SUITE=$1 WORK=$2; shift 2
if [[ ${SUITE} == */* ]]; then SUITE_DIR=${SUITE}; else SUITE_DIR="${HERE}/../suites/${SUITE}"; fi
[[ -f ${SUITE_DIR}/suite.env ]] || die "no suite ${SUITE} (${SUITE_DIR}/suite.env)"
SUITE_DIR=$(cd "${SUITE_DIR}" && pwd)
NAME=$(basename "${SUITE_DIR}")
[[ ! -e ${WORK} || -z $(ls -A "${WORK}") ]] || die "${WORK} is not empty"
mkdir -p "${WORK}/legs"
WORK=$(cd "${WORK}" && pwd)
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

UPSTREAM_REPO="" UPSTREAM_REF="" LEG_TIMEOUT_MINUTES=60 RUNNER_PASS_ENV=""
# shellcheck source=/dev/null
source "${SUITE_DIR}/suite.env"
TIMEOUT=${PGSQL3P_LEG_TIMEOUT_SECONDS:-$(( LEG_TIMEOUT_MINUTES * 60 ))}

suite_fail() {
    jq -n --arg r "$*" '{status: "infra_failure", reason: $r}' > "${WORK}/suite-status.json"
    die "${NAME}: $*"
}
# Files written by containers belong to root: hand them back to the calling user, so they can be
# read, updated and removed without sudo.
own() { docker run --rm -v "$1:/own" --entrypoint chown "${POSTGRES_IMAGE}" -R "$(id -u):$(id -g)" /own >/dev/null 2>&1 || true; }

# --- the upstream tests, at their pinned commit
UP="" UP_SHA=""
if [[ -n ${PGSQL3P_UPSTREAM_DIR:-} ]]; then
    UP=$(cd "${PGSQL3P_UPSTREAM_DIR}" && pwd); UP_SHA=$(git -C "${UP}" rev-parse HEAD 2>/dev/null || true)
elif [[ -n ${UPSTREAM_REPO} ]]; then
    UP="${WORK}/upstream"
    UP_SHA=$(bash "${HERE}/fetch-suite.sh" "${SUITE_DIR}" "${UP}") || suite_fail "fetching ${UPSTREAM_REPO} ${UPSTREAM_REF} failed"
fi

# --- certificates, and any other files the suite prepares (SUITE_WORK)
CERT_DIR="${WORK}/certs" SUITE_WORK="${WORK}/suite"
mkdir -p "${SUITE_WORK}"
if [[ -f ${SUITE_DIR}/prepare.sh ]]; then
    bash "${SUITE_DIR}/prepare.sh" "${UP}" "${CERT_DIR}" "${SUITE_WORK}" || suite_fail "${SUITE_DIR}/prepare.sh failed"
else
    bash "${HERE}/certs.sh" "${CERT_DIR}" >/dev/null || suite_fail "certs.sh failed"
fi

# --- the runner image: the suite's Dockerfile, context = the upstream checkout (or the suite folder),
# the suite folder as the extra build context "suite". --network=host: some developer machines' Docker
# build network has no egress; harmless on runners. 3 attempts (dependency downloads).
RUNNER_IMAGE="pgsql-3p-runner-${NAME}:latest"
for attempt in 1 2 3; do
    docker build --network=host -f "${SUITE_DIR}/Dockerfile" --build-context "suite=${SUITE_DIR}" \
        --build-arg "TEMURIN_IMAGE=${TEMURIN_IMAGE:-}" --build-arg "POSTGRES_IMAGE=${POSTGRES_IMAGE}" \
        -t "${RUNNER_IMAGE}" "${UP:-${SUITE_DIR}}" > "${WORK}/runner-build.log" 2>&1 && break
    [[ ${attempt} -lt 3 ]] || suite_fail "building the runner image failed 3 times (see runner-build.log)"
    echo "::warning::${NAME}: runner image build attempt ${attempt} failed, retrying in $(( 30 * attempt ))s" >&2
    sleep $(( 30 * attempt ))
done
RUNNER_ID=$(docker image inspect -f '{{.Id}}' "${RUNNER_IMAGE}")

# --- the legs
LEG_ROWS=()
FAILED_LEGS=0
for leg in "$@"; do
    D="${WORK}/legs/${leg}" A="${WORK}/legs/${leg}/artifacts"
    mkdir -p "${A}"
    ENVF="${WORK}/legs/${leg}.env"
    printf '%s\n' "RUNNER_IMAGE=${RUNNER_IMAGE}" "UPSTREAM_DIR=${UP:-${SUITE_DIR}}" "SUITE_WORK=${SUITE_WORK}" \
        "LEG_RESULTS_DIR=${A}" > "${ENVF}"
    echo "::group::${NAME} ${leg}"
    if SUITE_DIR="${SUITE_DIR}" SUITE_ENV_FILE="${ENVF}" CERT_DIR="${CERT_DIR}" bash "${HERE}/leg-up.sh" "${leg}" "${D}"; then
        set -a
        # shellcheck source=/dev/null
        source "${D}/conn.env"
        set +a
        CLIENT_TLS=$(jq -r .client_tls "${A}/leg.json") BACKEND_TLS=$(jq -r '.backend_tls // ""' "${A}/leg.json")
        export LEG=${leg} CLIENT_TLS BACKEND_TLS
        PASS=(-e PGHOST -e PGPORT -e PGDATABASE -e PGUSER -e PGPASSWORD -e PGSSLMODE -e PGCONNECT_TIMEOUT
              -e LEG -e CLIENT_TLS -e BACKEND_TLS)
        for v in ${RUNNER_PASS_ENV}; do [[ -n ${!v:-} ]] && PASS+=(-e "${v}"); done
        set +e
        timeout --kill-after=30 "${TIMEOUT}" docker compose --env-file "${D}/compose.env" run --rm --no-deps -T \
            "${PASS[@]}" runner > "${A}/test-output.log" 2>&1
        RC=$?
        set -e
        own "${A}"

        STATUS=completed
        if [[ ${RC} -eq 124 || ${RC} -eq 137 ]]; then STATUS=timed_out; fi
        TESTS=$(python3 -I "${HERE}/junit-counts.py" "${A}/junit")
        [[ ${TESTS} != null || ${STATUS} == timed_out ]] || STATUS=no_results
        if [[ $(jq -r .backend_tls "${A}/leg.json") != null ]]; then
            PX=$(docker compose --env-file "${D}/compose.env" ps -aq proxysql)
            STATE=$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "${PX}" 2>/dev/null || echo "missing 0")
            [[ ${STATE} == "true 0" ]] || STATUS=proxysql_crashed
        fi
        jq --arg s "${STATUS}" --argjson rc "${RC}" --argjson t "${TESTS}" \
            '.status = $s | .runner_exit_code = $rc | .tests = $t' "${A}/leg.json" > "${A}/leg.json.tmp"
        mv "${A}/leg.json.tmp" "${A}/leg.json"
        echo "${NAME} ${leg}: ${STATUS} (runner exit ${RC}, tests ${TESTS})"
    else
        FAILED_LEGS=$(( FAILED_LEGS + 1 ))
    fi
    bash "${HERE}/leg-down.sh" "${D}"
    own "${A}"
    LEG_ROWS+=("$(jq -c '{leg, client_tls, backend_tls, status, reason, tests, started_at, ended_at}' "${A}/leg.json")")
    echo "::endgroup::"
done

# --- what was tested, with what
jq -n --arg suite "${NAME}" --arg repo "${UPSTREAM_REPO}" --arg ref "${UPSTREAM_REF}" --arg sha "${UP_SHA}" \
    --arg px_sha "${PROXYSQL_SHA:-}" --arg px_version "${PROXYSQL_VERSION:-}" --arg px_image "${PROXYSQL_IMAGE:-}" \
    --arg px_id "${PROXYSQL_IMAGE_ID:-}" --arg pg "${POSTGRES_IMAGE}" --arg r_image "${RUNNER_IMAGE}" \
    --arg r_id "${RUNNER_ID}" --arg temurin "${TEMURIN_IMAGE:-}" \
    --arg repo_sha "$(git -C "${HERE}" rev-parse HEAD 2>/dev/null || true)" \
    --arg image_os "${ImageOS:-}" --arg image_version "${ImageVersion:-}" \
    --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" \
    --arg started "${STARTED}" --arg ended "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson legs "$(printf '%s\n' "${LEG_ROWS[@]}" | jq -s .)" \
    '{suite: $suite,
      upstream: (if $repo == "" then null else {repo: $repo, ref: $ref, sha: $sha} end),
      proxysql: {sha: $px_sha, version: $px_version, image: $px_image, image_id: $px_id},
      postgres_image: $pg, runner: {image: $r_image, image_id: $r_id, temurin_image: $temurin},
      repository_sha: $repo_sha, github_runner: {image_os: $image_os, image_version: $image_version},
      docker_version: $docker, started_at: $started, ended_at: $ended, legs: $legs}' > "${WORK}/metadata.json"
[[ ${FAILED_LEGS} -eq 0 ]] || { echo "::error::${NAME}: ${FAILED_LEGS} leg(s) infra_failure" >&2; exit 1; }
