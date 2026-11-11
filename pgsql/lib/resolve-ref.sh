#!/usr/bin/env bash
# Usage: resolve-ref.sh REF
# Prints the 40-hex commit of sysown/proxysql for REF: a branch name, or a full lowercase commit SHA
# (echoed as is). Only the SHA is passed on to the build, so the tested commit cannot change mid-run.
set -euo pipefail

# PROXYSQL_REPO_URL is only overridden by the tests (local repository)
REPO_URL="${PROXYSQL_REPO_URL:-https://github.com/sysown/proxysql.git}"

die() { echo "::error::$*" >&2; exit 1; }

REF="${1:-}"
[[ -n ${REF} ]] || die "empty ref (expected a sysown/proxysql branch or a full 40-hex commit)"

if [[ ${REF} =~ ^[0-9a-f]{40}$ ]]; then
    echo "${REF}"
    exit 0
fi

[[ ${REF} =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid ref '${REF}' (allowed: letters, digits, . _ / -; or a full lowercase 40-hex commit)"

LINES=$(git ls-remote "${REPO_URL}" "refs/heads/${REF}") || die "git ls-remote ${REPO_URL} failed"
COUNT=$(grep -c . <<< "${LINES}" || true)
[[ ${COUNT} -eq 1 ]] || die "branch '${REF}' not found in ${REPO_URL} (${COUNT} matches)"

SHA=${LINES%%[[:space:]]*}
[[ ${SHA} =~ ^[0-9a-f]{40}$ ]] || die "unexpected ls-remote output: ${LINES}"
echo "${SHA}"
