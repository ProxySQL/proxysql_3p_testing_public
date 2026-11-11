#!/usr/bin/env bash
# Usage: legs-summary.sh LEGS_DIR LEG...
# Prints a Markdown table with one row per leg from LEGS_DIR/<leg>/artifacts/leg.json (for the run
# page summary): status, test counts, reason, PostgreSQL version, backend protocol, ProxySQL config.
# Exits 1, naming them, if any leg's setup failed (infra_failure) or a leg has no leg.json. Test
# outcomes (completed, timed_out, no_results, proxysql_crashed) are reported, not failed on here.
set -euo pipefail

[[ $# -ge 2 ]] || { echo "::error::usage: legs-summary.sh LEGS_DIR LEG..." >&2; exit 1; }
DIR=$1; shift
FAILED=""
echo "| Leg | Status | Tests | Failed | Errors | Skipped | Reason | Server version | Backend protocol | ProxySQL config SHA-256 |"
echo "|---|---|---|---|---|---|---|---|---|---|"
for leg in "$@"; do
    F="${DIR}/${leg}/artifacts/leg.json"
    if [[ -f ${F} ]]; then
        # one line per row: newlines flattened, '|' escaped
        jq -r 'def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
            def n(k): if .tests == null then "-" else .tests[k] | cell end;
            "| \(.leg | cell) | \(.status | cell) | \(n("total")) | \(n("failures")) | \(n("errors")) | \(n("skipped")) | \(.reason // "" | cell) | \(.server_version // "-" | cell) | \(.backend_protocol // "-" | cell) | \(.proxysql_config_sha256 // "-" | cell) |"' "${F}"
        [[ $(jq -r .status "${F}") != infra_failure ]] || FAILED+=" ${leg}"
    else
        echo "| ${leg} | no leg.json | | | | | | | | |"
        FAILED+=" ${leg}"
    fi
done
[[ -z ${FAILED} ]] || { echo "::error::legs whose setup failed:${FAILED}" >&2; exit 1; }
