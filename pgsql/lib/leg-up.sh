#!/usr/bin/env bash
# Usage: leg-up.sh LEG LEG_DIR      (env: CERT_DIR; PROXYSQL_IMAGE for proxy legs; optional SUITE_DIR,
#                                   SUITE_ENV_FILE)
# Starts one leg's environment (pgsql/docker/compose.yml), prepares PostgreSQL, configures ProxySQL with
# its defaults plus the minimum the leg needs, and proves the connection and TLS state.
# Writes LEG_DIR/artifacts/leg.json with status "ready" (exit 0) or "infra_failure" and a reason (exit 1).
# Private files (never upload): LEG_DIR/compose.env, conn.env, pg-admin.env, secrets.
# Suite mode (SUITE_DIR set): the suite's compose.yml is added on top of pgsql/docker/compose.yml (its own
# PostgreSQL setup, its runner), its PROXYSQL_USERS and SUITE_DATABASE are used instead of the pgsql3p
# user, and NETWORK_MODE=shared makes clients use the target's network (PGHOST=localhost).
# SUITE_ENV_FILE: extra KEY=VALUE lines for the compose files (e.g. paths of the fetched upstream).
set -Eeuo pipefail   # -E: the ERR trap also fires inside functions

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../versions.env
source "${HERE}/../versions.env"

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: leg-up.sh LEG LEG_DIR"
LEG=$1 LEG_DIR=$2
#                         target   port client_tls backend_tls
case ${LEG} in
    direct-plain)    set -- pg       5432 0 "" ;;
    direct-tls)      set -- pg       5432 1 "" ;;
    proxy-plain)     set -- proxysql 6133 0 0 ;;
    proxy-tls)       set -- proxysql 6133 1 1 ;;
    proxy-tls-front) set -- proxysql 6133 1 0 ;;
    proxy-tls-back)  set -- proxysql 6133 0 1 ;;
    *) die "unknown leg '${LEG}'" ;;
esac
TARGET=$1 PORT=$2 CLIENT_TLS=$3 BACKEND_TLS=$4
PROXY=0 PROFILES=""
if [[ ${TARGET} == proxysql ]]; then PROXY=1 PROFILES=proxy; fi

mkdir -p "${LEG_DIR}/artifacts"
LEG_DIR=$(cd "${LEG_DIR}" && pwd)
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STEP=init ERR="" SERVER_VERSION="" CONFIG_SHA="" BACKEND_PROTOCOL=""

write_json() {
    jq -n --arg leg "${LEG}" --arg target "${TARGET}:${PORT}" \
        --argjson client_tls "${CLIENT_TLS}" --argjson backend_tls "${BACKEND_TLS:-null}" \
        --arg status "$1" --arg reason "$2" --arg started_at "${STARTED}" \
        --arg postgres_image "${POSTGRES_IMAGE}" --arg proxysql_image "${PROXYSQL_IMAGE:-}" \
        --arg server_version "${SERVER_VERSION}" --arg config_sha "${CONFIG_SHA}" --argjson proxy "${PROXY}" \
        --arg backend_protocol "${BACKEND_PROTOCOL}" \
        '{leg: $leg, target: $target, client_tls: $client_tls, backend_tls: $backend_tls,
          status: $status, reason: ($reason | gsub("[\r\n]+"; " ")), started_at: $started_at, ended_at: null,
          postgres_image: $postgres_image,
          proxysql_image: (if $proxy == 1 then $proxysql_image else null end),
          server_version: (if $server_version == "" then null else $server_version end),
          backend_protocol: (if $backend_protocol == "" then null else $backend_protocol end),
          proxysql_config_sha256: (if $config_sha == "" then null else $config_sha end)}' \
        > "${LEG_DIR}/artifacts/leg.json"
}
fail() { ERR=$*; exit 1; }
# shellcheck disable=SC2317  # trap handlers
on_err() { [[ -n ${ERR} ]] || ERR="command failed: ${BASH_COMMAND}"; }
# shellcheck disable=SC2317
on_exit() {
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        write_json infra_failure "${STEP}: ${ERR:-exit ${rc}}"
        echo "::error::${LEG}: infra_failure: ${STEP}: ${ERR:-exit ${rc}}" >&2
    fi
}
trap on_err ERR
trap on_exit EXIT
# stopped from outside (run-suite.sh's time limit): still record infra_failure on the way out
trap 'ERR="stopped (time limit)"; exit 143' TERM

STEP="check inputs"
[[ -n ${CERT_DIR:-} && -f ${CERT_DIR}/server.pem ]] || fail "CERT_DIR must point to a certs.sh directory"
CERT_DIR=$(cd "${CERT_DIR}" && pwd)
[[ ${PROXY} -eq 0 || -n ${PROXYSQL_IMAGE:-} ]] || fail "PROXYSQL_IMAGE is required for proxysql legs"

COMPOSE_FILES="${HERE}/../docker/compose.yml" PROXYSQL_USERS="" SUITE_DATABASE="" NETWORK_MODE=""
if [[ -n ${SUITE_DIR:-} ]]; then
    STEP="read suite settings"
    SUITE_DIR=$(cd "${SUITE_DIR}" && pwd)
    # shellcheck source=/dev/null
    source "${SUITE_DIR}/suite.env"
    [[ -n ${PROXYSQL_USERS} && -n ${SUITE_DATABASE} ]] || fail "${SUITE_DIR}/suite.env needs PROXYSQL_USERS and SUITE_DATABASE"
    for pair in ${PROXYSQL_USERS}; do
        [[ ${pair} =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]] || fail "PROXYSQL_USERS entry '${pair}' is not user:password"
    done
    [[ -f ${SUITE_DIR}/compose.yml ]] && COMPOSE_FILES+=":${SUITE_DIR}/compose.yml"
    [[ -z ${SUITE_ENV_FILE:-} || -f ${SUITE_ENV_FILE} ]] || fail "SUITE_ENV_FILE ${SUITE_ENV_FILE} not found"
fi
CLIENT_SERVICE=client HOST=${TARGET}
if [[ ${NETWORK_MODE} == shared ]]; then CLIENT_SERVICE=client-shared HOST=localhost; fi

STEP="write leg settings"
umask 077
SUPER_PW=$(openssl rand -hex 12) APP_PW=$(openssl rand -hex 12)
# the users ProxySQL gets, and the one clients and the proof connect as (the first)
USERS=${PROXYSQL_USERS:-pgsql3p:${APP_PW}} DATABASE=${SUITE_DATABASE:-pgsql3p}
FIRST=${USERS%% *} CONN_USER=${FIRST%%:*} CONN_PW=${FIRST#*:}
cat > "${LEG_DIR}/compose.env" <<EOF
COMPOSE_PROJECT_NAME=pgsql3p-${LEG}-$(openssl rand -hex 4)
COMPOSE_FILE=${COMPOSE_FILES}
COMPOSE_PROFILES=${PROFILES}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
PROXYSQL_IMAGE=${PROXYSQL_IMAGE:-}
CERT_DIR=${CERT_DIR}
PG_SUPERUSER_PASSWORD=${SUPER_PW}
LEG_TARGET=${TARGET}
CLIENT_SERVICE=${CLIENT_SERVICE}
SUITE_DIR=${SUITE_DIR:-}
EOF
[[ -z ${SUITE_ENV_FILE:-} ]] || cat "${SUITE_ENV_FILE}" >> "${LEG_DIR}/compose.env"
# suite passwords in PROXYSQL_USERS are the upstream's public test credentials, not secrets
printf '%s\n' "${SUPER_PW}" "${APP_PW}" > "${LEG_DIR}/secrets"
cat > "${LEG_DIR}/conn.env" <<EOF
PGHOST=${HOST}
PGPORT=${PORT}
PGDATABASE=${DATABASE}
PGUSER=${CONN_USER}
PGPASSWORD=${CONN_PW}
PGSSLMODE=$([[ ${CLIENT_TLS} == 1 ]] && echo verify-full || echo disable)
PGSSLROOTCERT=/tls/ca.pem
PGCONNECT_TIMEOUT=10
EOF
cat > "${LEG_DIR}/pg-admin.env" <<EOF
PGHOST=pg
PGPORT=5432
PGDATABASE=postgres
PGUSER=postgres
PGPASSWORD=${SUPER_PW}
PGSSLMODE=disable
EOF
umask 022
cp "${CERT_DIR}/cert-metadata.txt" "${LEG_DIR}/artifacts/"
# an array, not a function: a failing call then shows up in the reason as the line that ran it
DC=(docker compose --env-file "${LEG_DIR}/compose.env")
psql_pg() { "${DC[@]}" exec -T pg psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }

STEP="start postgresql"
"${DC[@]}" up -d --quiet-pull --wait --wait-timeout 120 pg

STEP="prepare postgresql"
# 'monitor'/'monitor' are ProxySQL's default monitor credentials, so ProxySQL's monitor settings stay default
# (a suite's own PostgreSQL setup creates its users and databases itself)
if [[ -z ${SUITE_DIR:-} ]]; then
    psql_pg -q <<EOF
CREATE ROLE pgsql3p LOGIN PASSWORD '${APP_PW}';
CREATE DATABASE pgsql3p OWNER pgsql3p;
EOF
fi
psql_pg -q -c "CREATE ROLE monitor LOGIN PASSWORD 'monitor'"
SERVER_VERSION=$(psql_pg -tAc 'SHOW server_version')
psql_pg -c 'SHOW ALL' > "${LEG_DIR}/artifacts/postgresql-settings.txt"

if [[ ${PROXY} -eq 1 ]]; then
    # ProxySQL's admin interface over its PostgreSQL protocol port, tab-separated rows without headers
    admin() { "${DC[@]}" run --rm --no-deps -T admin -h 127.0.0.1 -p 6132 -U admin -d admin -X -q -tA -F $'\t' -v ON_ERROR_STOP=1 "$@"; }

    STEP="start proxysql"
    "${DC[@]}" up -d --quiet-pull proxysql
    for _ in $(seq 60); do
        admin -c 'SELECT 1' >/dev/null 2>&1 && break
        [[ $(docker inspect -f '{{.State.Running}}' "$("${DC[@]}" ps -aq proxysql)") == true ]] || fail "proxysql container exited"
        sleep 1
    done
    admin -c 'SELECT 1' >/dev/null 2>&1 || fail "proxysql admin port 6132 not reachable after 60s"

    STEP="configure proxysql"
    USER_ROWS=""
    for pair in ${USERS}; do
        USER_ROWS+="INSERT INTO pgsql_users (username, password, fast_forward, default_hostgroup) VALUES ('${pair%%:*}', '${pair#*:}', 0, 0);"$'\n'
    done
    OUT=$(admin 2>&1 <<EOF
DELETE FROM pgsql_users;
${USER_ROWS}
DELETE FROM pgsql_servers;
INSERT INTO pgsql_servers (hostgroup_id, hostname, port, use_ssl) VALUES (0, 'pg', 5432, ${BACKEND_TLS});
UPDATE global_variables SET variable_value = '${SERVER_VERSION}' WHERE variable_name = 'pgsql-server_version';
LOAD PGSQL USERS TO RUNTIME;
LOAD PGSQL SERVERS TO RUNTIME;
LOAD PGSQL VARIABLES TO RUNTIME;
EOF
    ) || fail "proxysql admin: ${OUT}"

    STEP="check backend protocol"
    NATIVE=$(admin -c "SELECT variable_value FROM runtime_global_variables WHERE variable_name = 'pgsql-use_native_backend_protocol'")
    [[ ${NATIVE} == true ]] || fail "pgsql-use_native_backend_protocol is '${NATIVE}', expected 'true' (native backend protocol)"
    BACKEND_PROTOCOL=native

    STEP="dump proxysql config"
    # configuration only (no runtime state such as server status); password values masked
    {
        echo "== runtime_global_variables (pgsql-%)"
        admin -c "SELECT variable_name, CASE WHEN variable_name LIKE '%password%' THEN '***' ELSE variable_value END
                  FROM runtime_global_variables WHERE variable_name LIKE 'pgsql-%' ORDER BY variable_name"
        echo "== runtime_pgsql_servers"
        admin -c "SELECT hostgroup_id, hostname, port, weight, compression, max_connections, max_replication_lag,
                  use_ssl, max_latency_ms, comment FROM runtime_pgsql_servers ORDER BY hostgroup_id, hostname, port"
        echo "== runtime_pgsql_users (without password)"
        admin -c "SELECT username, active, use_ssl, default_hostgroup, transaction_persistent, fast_forward, backend,
                  frontend, max_connections, attributes, comment FROM runtime_pgsql_users ORDER BY username, frontend"
    } > "${LEG_DIR}/artifacts/proxysql-config.txt"
    CONFIG_SHA=$(sha256sum "${LEG_DIR}/artifacts/proxysql-config.txt" | cut -d' ' -f1)
fi

STEP="prove connection and tls"
EXPECT_SSL=$([[ ${PROXY} -eq 1 ]] && echo "${BACKEND_TLS}" || echo "${CLIENT_TLS}")
# ProxySQL may still be opening its first backend connection: retry until 30 s have passed
DEADLINE=$(( SECONDS + 30 ))
until PROOF=$(bash "${HERE}/prove-tls.sh" "${LEG_DIR}" "${CLIENT_TLS}" "${EXPECT_SSL}" 2>&1); do
    (( SECONDS < DEADLINE )) || break
    sleep 2
done
[[ ${PROOF} == ok:* ]] || fail "${PROOF//::error::/}"
echo "${PROOF}" > "${LEG_DIR}/artifacts/tls-proof.txt"

write_json ready ""
echo "${LEG}: ready (${PROOF})"
