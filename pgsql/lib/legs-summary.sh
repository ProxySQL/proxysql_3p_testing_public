#!/usr/bin/env bash
# Usage: legs-summary.sh LEGS_DIR LEG...
# Prints a Markdown table with one row per leg from LEGS_DIR/<leg>/artifacts/leg.json (for the run
# page summary). Exits 1, naming them, if any leg is not ready or has no leg.json.
set -euo pipefail

[[ $# -ge 2 ]] || { echo "::error::usage: legs-summary.sh LEGS_DIR LEG..." >&2; exit 1; }
DIR=$1; shift
NOT_READY=""
echo "| Leg | Status | Reason | Server version | Backend protocol | ProxySQL config SHA-256 |"
echo "|---|---|---|---|---|---|"
for leg in "$@"; do
    F="${DIR}/${leg}/artifacts/leg.json"
    if [[ -f ${F} ]]; then
        # one line per row: newlines flattened, '|' escaped
        jq -r 'def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
            "| \(.leg | cell) | \(.status | cell) | \(.reason | cell) | \(.server_version // "-" | cell) | \(.backend_protocol // "-" | cell) | \(.proxysql_config_sha256 // "-" | cell) |"' "${F}"
        [[ $(jq -r .status "${F}") == ready ]] || NOT_READY+=" ${leg}"
    else
        echo "| ${leg} | no leg.json | | | | |"
        NOT_READY+=" ${leg}"
    fi
done
[[ -z ${NOT_READY} ]] || { echo "::error::legs not ready:${NOT_READY}" >&2; exit 1; }
