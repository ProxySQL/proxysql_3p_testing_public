#!/usr/bin/env bash
# Tests for pgsql/lib/resolve-ref.sh. Needs network access to github.com.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/resolve-ref.sh"
FAILED=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# expect_ok NAME REF REGEX: exit 0 and stdout matches REGEX
expect_ok() {
    local out rc
    out=$(bash "${SCRIPT}" "$2" 2>/dev/null); rc=$?
    if [[ ${rc} -eq 0 && ${out} =~ $3 ]]; then pass "$1"; else fail "$1 (rc=${rc}, out='${out}')"; fi
}

# expect_err NAME REF: exit 1 (the script's own error, not "command not found") with an error message
expect_err() {
    local err rc
    err=$(bash "${SCRIPT}" "$2" 2>&1 >/dev/null); rc=$?
    if [[ ${rc} -eq 1 && ${err} == *error* ]]; then pass "$1"; else fail "$1 (rc=${rc}, stderr='${err}')"; fi
}

expect_ok  "branch v3.0 resolves to a full sha" "v3.0" '^[0-9a-f]{40}$'
expect_ok  "full sha is echoed" "e30a016be613a9e9758f03df78f462b99efd2974" '^e30a016be613a9e9758f03df78f462b99efd2974$'
expect_err "shell metacharacters rejected" 'v3.0;id'
expect_err "empty ref rejected" ''
expect_err "unknown branch rejected" "no-such-branch-pgsql-3p"
expect_err "uppercase sha rejected" "E30A016BE613A9E9758F03DF78F462B99EFD2974"

# Branch names with a slash, against a local repository (deterministic, no network).
LOCAL=$(mktemp -d)
trap 'rm -rf "${LOCAL}"' EXIT
git -C "${LOCAL}" init -q -b main
git -C "${LOCAL}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "${LOCAL}" branch feature/x
git -C "${LOCAL}" branch x   # 'x' must not also match 'feature/x'
WANT=$(git -C "${LOCAL}" rev-parse HEAD)
export PROXYSQL_REPO_URL="${LOCAL}"
expect_ok  "branch with a slash resolves" "feature/x" "^${WANT}$"
expect_ok  "short name does not match a longer branch" "x" "^${WANT}$"
unset PROXYSQL_REPO_URL

exit "${FAILED}"
