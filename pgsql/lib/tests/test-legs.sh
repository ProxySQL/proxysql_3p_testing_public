#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for leg-up.sh, prove-tls.sh and leg-down.sh: every leg comes up ready with the right TLS state,
# wrong TLS expectations fail, a missing image is an infra_failure, and nothing is left behind.
# Needs docker, jq, openssl and a local ProxySQL image named in PROXYSQL_IMAGE (see pgsql/README.md).
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z ${PROXYSQL_IMAGE:-} ]] || ! docker image inspect "${PROXYSQL_IMAGE}" >/dev/null 2>&1; then
    echo "FAIL: set PROXYSQL_IMAGE to a local ProxySQL image (pgsql/README.md, 'Testing the scripts locally')"
    exit 1
fi
TMP=$(mktemp -d)
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# shellcheck disable=SC2317  # called by the EXIT trap
cleanup() {
    for d in "${TMP}"/*/; do [[ -f ${d}compose.env ]] && bash "${LIB}/leg-down.sh" "${d%/}" >/dev/null 2>&1; done
    rm -rf "${TMP}"
}
trap cleanup EXIT

export CERT_DIR="${TMP}/certs"
bash "${LIB}/certs.sh" "${CERT_DIR}" >/dev/null || { echo "FAIL: certs.sh"; exit 1; }

field() { jq -r "$2" "$1/artifacts/leg.json" 2>/dev/null; }
project() { sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$1/compose.env"; }
leftovers() {
    local f="label=com.docker.compose.project=$1"
    { docker ps -aq --filter "${f}"; docker network ls -q --filter "${f}"; docker volume ls -q --filter "${f}"; } | wc -l
}

# check_leg LEG CLIENT_TLS BACKEND_TLS SSLMODE  (BACKEND_TLS "null" for direct legs)
check_leg() {
    local leg=$1 ctls=$2 btls=$3 mode=$4 d="${TMP}/$1" rc p
    if [[ ${leg} == direct-* ]]; then
        env -u PROXYSQL_IMAGE bash "${LIB}/leg-up.sh" "${leg}" "${d}" >"${TMP}/${leg}.out" 2>&1; rc=$?
    else
        bash "${LIB}/leg-up.sh" "${leg}" "${d}" >"${TMP}/${leg}.out" 2>&1; rc=$?
    fi
    [[ ${rc} -eq 0 && $(field "${d}" .status) == ready && $(field "${d}" .client_tls) == "${ctls}" \
        && $(field "${d}" .backend_tls) == "${btls}" && $(field "${d}" .server_version) == 18.6* ]] \
        && pass "${leg}: ready, client_tls=${ctls} backend_tls=${btls}, server 18.6" \
        || fail "${leg}: leg-up rc=${rc} leg.json=$(cat "${d}/artifacts/leg.json" 2>/dev/null) out=$(tail -n5 "${TMP}/${leg}.out")"

    grep -qx "PGSSLMODE=${mode}" "${d}/conn.env" 2>/dev/null && pass "${leg}: conn.env PGSSLMODE=${mode}" \
        || fail "${leg}: conn.env PGSSLMODE (want ${mode})"

    if [[ ${leg} == proxy-* ]]; then
        [[ $(field "${d}" .backend_protocol) == native && $(field "${d}" .proxysql_config_sha256) =~ ^[0-9a-f]{64}$ ]] \
            && grep -qE '^pgsql-use_native_backend_protocol[[:space:]]+true$' "${d}/artifacts/proxysql-config.txt" \
            && pass "${leg}: native backend protocol, config dumped and fingerprinted" \
            || fail "${leg}: backend protocol / config dump"
    fi

    bash "${LIB}/guard-artifacts.sh" "${d}/artifacts" "${d}/secrets" >/dev/null 2>&1 \
        && pass "${leg}: artifacts hold no keys or passwords" || fail "${leg}: guard found secrets in artifacts"

    case ${leg} in
        proxy-plain) bash "${LIB}/prove-tls.sh" "${d}" 0 1 >/dev/null 2>&1 \
            && fail "proxy-plain: proof expecting backend TLS passed" || pass "proxy-plain: proof expecting backend TLS fails" ;;
        direct-tls) bash "${LIB}/prove-tls.sh" "${d}" 1 0 >/dev/null 2>&1 \
            && fail "direct-tls: proof expecting no TLS passed" || pass "direct-tls: proof expecting no TLS fails" ;;
    esac

    case ${leg} in
        direct-plain)  # a one-off container (as a stage 3 suite runner will be) must not survive leg-down
            docker compose --env-file "${d}/compose.env" run -d --no-deps --entrypoint sleep client 600 >/dev/null 2>&1 ;;
        proxy-plain)   # a ProxySQL that accepts TCP but never answers must not hang the proof
            grep -qx 'PGCONNECT_TIMEOUT=10' "${d}/conn.env" && pass "proxy-plain: conn.env sets PGCONNECT_TIMEOUT=10" \
                || fail "proxy-plain: conn.env has no PGCONNECT_TIMEOUT=10"
            docker compose --env-file "${d}/compose.env" pause proxysql >/dev/null 2>&1
            local t0=${SECONDS}
            timeout 120 bash "${LIB}/prove-tls.sh" "${d}" 0 0 >/dev/null 2>&1; rc=$?
            [[ ${rc} -eq 1 && $(( SECONDS - t0 )) -lt 60 ]] && pass "proxy-plain: proof fails within 60s when ProxySQL hangs ($(( SECONDS - t0 ))s)" \
                || fail "proxy-plain: hung ProxySQL: proof rc=${rc} after $(( SECONDS - t0 ))s"
            docker compose --env-file "${d}/compose.env" unpause proxysql >/dev/null 2>&1 ;;
    esac

    p=$(project "${d}")
    bash "${LIB}/leg-down.sh" "${d}" >/dev/null 2>&1; rc=$?
    local logs_ok=1
    [[ -s ${d}/artifacts/postgresql.log ]] || logs_ok=0
    [[ ${leg} == direct-* || -s ${d}/artifacts/proxysql.log ]] || logs_ok=0
    [[ ${rc} -eq 0 && -n ${p} && $(leftovers "${p}") -eq 0 && ${logs_ok} -eq 1 && $(field "${d}" .ended_at) != null ]] \
        && pass "${leg}: leg-down collects logs and leaves nothing behind" \
        || fail "${leg}: leg-down rc=${rc} project='${p}' leftovers=$(leftovers "${p}") logs_ok=${logs_ok}"
    rm -f "${d}/compose.env"
}

check_leg direct-plain    0 null disable
check_leg direct-tls      1 null verify-full
check_leg proxy-plain     0 0    disable
check_leg proxy-tls       1 1    verify-full
check_leg proxy-tls-front 1 0    verify-full
check_leg proxy-tls-back  0 1    disable

# suite mode: the suite's PostgreSQL setup, users and database, and a shared network (PGHOST=localhost)
SUITE="${LIB}/tests/fixtures/suite-min"
# what run-suite.sh passes for the suite's compose.yml (its runner is not started here)
printf '%s\n' "RUNNER_IMAGE=unused" "LEG_RESULTS_DIR=${TMP}/unused" > "${TMP}/suite.env"
for leg in direct-plain proxy-tls; do
    D="${TMP}/suite-${leg}"
    SUITE_DIR="${SUITE}" SUITE_ENV_FILE="${TMP}/suite.env" bash "${LIB}/leg-up.sh" "${leg}" "${D}" >"${TMP}/suite-${leg}.out" 2>&1; RC=$?
    WANT_PORT=$([[ ${leg} == proxy-* ]] && echo 6133 || echo 5432)
    [[ ${RC} -eq 0 && $(field "${D}" .status) == ready ]] && grep -qx PGHOST=localhost "${D}/conn.env" \
        && grep -qx PGUSER=alice "${D}/conn.env" && grep -qx PGDATABASE=alicedb "${D}/conn.env" \
        && grep -qx "PGPORT=${WANT_PORT}" "${D}/conn.env" \
        && pass "suite ${leg}: ready, conn.env localhost:${WANT_PORT} as alice@alicedb" \
        || fail "suite ${leg}: rc=${RC} leg.json=$(cat "${D}/artifacts/leg.json" 2>/dev/null) out=$(tail -n3 "${TMP}/suite-${leg}.out")"
    if [[ ${leg} == proxy-* ]]; then
        ADMIN=(docker compose --env-file "${D}/compose.env" run --rm --no-deps -T admin -h 127.0.0.1 -p 6132 -U admin -d admin -XqtA)
        USERS=$("${ADMIN[@]}" -c "SELECT username FROM runtime_pgsql_users ORDER BY username" 2>/dev/null | sort -u | paste -sd,)
        CREATED=$("${ADMIN[@]}" -c "SELECT variable_value FROM stats_pgsql_global WHERE variable_name = 'Client_Connections_created'" 2>/dev/null)
        [[ ${USERS} == alice && ${CREATED:-0} -gt 0 ]] \
            && pass "suite ${leg}: ProxySQL has only the suite's user, and the proof went through ProxySQL (${CREATED} client connections)" \
            || fail "suite ${leg}: users='${USERS}' client connections='${CREATED}'"
    fi
    P=$(project "${D}"); bash "${LIB}/leg-down.sh" "${D}" >/dev/null 2>&1; rm -f "${D}/compose.env"
    [[ $(leftovers "${P}") -eq 0 ]] || fail "suite ${leg}: leftovers"
done

# forced setup failure: the ProxySQL image does not exist
D="${TMP}/missing-image"
START=$(date +%s)
PROXYSQL_IMAGE=pgsql-3p-no-such-image:none timeout 180 bash "${LIB}/leg-up.sh" proxy-plain "${D}" >"${TMP}/missing.out" 2>&1; RC=$?
ELAPSED=$(( $(date +%s) - START ))
[[ ${RC} -eq 1 && $(field "${D}" .status) == infra_failure && $(field "${D}" .reason) == *proxysql* \
    && $(field "${D}" .reason) == *"up -d"* && $(field "${D}" .backend_protocol) == null ]] \
    && pass "missing ProxySQL image: infra_failure after ${ELAPSED}s, reason names the failed command, no backend protocol claimed" \
    || fail "missing image: rc=${RC} leg.json=$(cat "${D}/artifacts/leg.json" 2>/dev/null)"
P=$(project "${D}" 2>/dev/null)
bash "${LIB}/leg-down.sh" "${D}" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 0 && -n ${P} && $(leftovers "${P}") -eq 0 ]] && pass "missing image: leg-down cleans up" \
    || fail "missing image: leg-down rc=${RC} leftovers=$(leftovers "${P}")"
rm -f "${D}/compose.env"

# stopped from outside (run-suite.sh's time limit on the whole setup): still recorded as infra_failure
D="${TMP}/stopped"
timeout 3 bash "${LIB}/leg-up.sh" proxy-plain "${D}" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 124 && $(field "${D}" .status) == infra_failure && $(field "${D}" .reason) == *"stopped (time limit)"* ]] \
    && pass "setup stopped by a time limit is recorded as infra_failure ($(field "${D}" .reason))" \
    || fail "stopped setup: rc=${RC} leg.json=$(cat "${D}/artifacts/leg.json" 2>/dev/null)"
P=$(project "${D}" 2>/dev/null); bash "${LIB}/leg-down.sh" "${D}" >/dev/null 2>&1; rm -f "${D}/compose.env"
[[ -z ${P} || $(leftovers "${P}") -eq 0 ]] || fail "stopped setup: leftovers"

bash "${LIB}/leg-up.sh" no-such-leg "${TMP}/bad" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 1 ]] && pass "unknown leg name fails" || fail "unknown leg (rc=${RC})"

exit "${FAILED}"
