#!/usr/bin/env bash
# Usage: prove-tls.sh LEG_DIR EXPECT_CLIENT_TLS EXPECT_SSL
# Connects to the leg's endpoint (conn.env) with sslmode=verify-full when EXPECT_CLIENT_TLS is 1, or
# sslmode=disable when 0, and checks PostgreSQL's view of its own connection: pg_stat_ssl.ssl must be
# EXPECT_SSL (1/0). Direct legs: that is the client's connection; proxy legs: ProxySQL's backend one.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 3 && $2 =~ ^[01]$ && $3 =~ ^[01]$ ]] || die "usage: prove-tls.sh LEG_DIR EXPECT_CLIENT_TLS(0|1) EXPECT_SSL(0|1)"
LEG_DIR=$1 CLIENT_TLS=$2 EXPECT_SSL=$3
[[ -f ${LEG_DIR}/conn.env && -f ${LEG_DIR}/compose.env ]] || die "${LEG_DIR} has no conn.env/compose.env (run leg-up.sh first)"

set -a
# shellcheck source=/dev/null
source "${LEG_DIR}/conn.env"
set +a
if [[ ${CLIENT_TLS} == 1 ]]; then PGSSLMODE=verify-full; else PGSSLMODE=disable; fi
WANT=$([[ ${EXPECT_SSL} == 1 ]] && echo t || echo f)
# client-shared (suite NETWORK_MODE=shared) runs in the target's network and connects to localhost
SERVICE=$(sed -n 's/^CLIENT_SERVICE=//p' "${LEG_DIR}/compose.env")

# PGCONNECT_TIMEOUT (conn.env) bounds the connection; timeout is the backstop if psql itself hangs
OUT=$(timeout 30 docker compose --env-file "${LEG_DIR}/compose.env" run --rm --no-deps -T \
    -e PGHOST -e PGPORT -e PGDATABASE -e PGUSER -e PGPASSWORD -e PGSSLMODE -e PGSSLROOTCERT -e PGCONNECT_TIMEOUT \
    "${SERVICE:-client}" -XtA -v ON_ERROR_STOP=1 -c "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()" 2>&1) \
    || die "connection to ${PGHOST}:${PGPORT} with sslmode=${PGSSLMODE} failed: ${OUT}"
GOT=$(tail -n1 <<< "${OUT}")
[[ ${GOT} == "${WANT}" ]] || die "pg_stat_ssl.ssl is '${GOT}', expected '${WANT}' (${PGHOST}:${PGPORT}, sslmode=${PGSSLMODE})"
echo "ok: ${PGHOST}:${PGPORT} sslmode=${PGSSLMODE}, pg_stat_ssl.ssl=${GOT}"
