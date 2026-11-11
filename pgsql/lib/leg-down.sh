#!/usr/bin/env bash
# Usage: leg-down.sh LEG_DIR
# Collects the leg's container logs and state into LEG_DIR/artifacts, sets ended_at in leg.json, and
# removes the leg's containers, networks and volumes. Safe to run after a partial or failed leg-up.sh.
set -uo pipefail

[[ $# -eq 1 ]] || { echo "::error::usage: leg-down.sh LEG_DIR" >&2; exit 1; }
LEG_DIR=$1
A="${LEG_DIR}/artifacts"
mkdir -p "${A}"

if [[ -f ${LEG_DIR}/compose.env ]]; then
    dc() { docker compose --env-file "${LEG_DIR}/compose.env" "$@"; }
    dc logs --no-color --timestamps pg > "${A}/postgresql.log" 2>&1
    if grep -q '^COMPOSE_PROFILES=proxy$' "${LEG_DIR}/compose.env"; then
        dc logs --no-color --timestamps proxysql > "${A}/proxysql.log" 2>&1
        dc cp proxysql:/var/lib/proxysql/proxysql.log "${A}/proxysql-errorlog.log" >/dev/null 2>&1 \
            || rm -f "${A}/proxysql-errorlog.log"
    fi
    # all containers of the project, including one-off 'docker compose run' containers, which 'down'
    # does not remove for services behind a profile
    PROJECT=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "${LEG_DIR}/compose.env")
    IDS=$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}")
    if [[ -n ${IDS} ]]; then
        # shellcheck disable=SC2086  # one argument per container id
        docker inspect ${IDS} | jq '[.[] | {service: .Config.Labels["com.docker.compose.service"],
            status: .State.Status, exit_code: .State.ExitCode, restart_count: .RestartCount,
            oom_killed: .State.OOMKilled}]' > "${A}/containers.json"
    else
        echo '[]' > "${A}/containers.json"
    fi
    # shellcheck disable=SC2086  # one argument per container id
    [[ -z ${IDS} ]] || docker rm -f -v ${IDS} >/dev/null 2>&1
    dc down -v --remove-orphans --timeout 10 >/dev/null 2>&1 || echo "::warning::docker compose down failed for ${LEG_DIR}" >&2
fi

if [[ -f ${A}/leg.json ]]; then
    jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.ended_at = $t' "${A}/leg.json" > "${A}/leg.json.tmp" \
        && mv "${A}/leg.json.tmp" "${A}/leg.json"
fi
exit 0
