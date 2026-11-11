#!/usr/bin/env bash
# Usage: guard-artifacts.sh DIR SECRETS_FILE
# Fails if any file under DIR contains a private key or any non-empty line of SECRETS_FILE (one
# secret per line). Run it before uploading DIR as an artifact. Names offending files, never secrets.
# Binary files and symlinked files are checked too (upload-artifact follows symlinks).
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: guard-artifacts.sh DIR SECRETS_FILE"
DIR=$1 SECRETS_FILE=$2
[[ -d ${DIR} ]] || die "no directory ${DIR}"
[[ -f ${SECRETS_FILE} ]] || die "no secrets file ${SECRETS_FILE}"

PATTERNS=$(mktemp)
trap 'rm -f "${PATTERNS}"' EXIT
# an empty pattern would match every file
grep -v '^$' "${SECRETS_FILE}" > "${PATTERNS}" || true

BAD=0
while IFS= read -r f; do
    echo "::error::private key in ${f}"; BAD=1
done < <(grep -Rl -- 'PRIVATE KEY' "${DIR}" || true)
if [[ -s ${PATTERNS} ]]; then
    while IFS= read -r f; do
        echo "::error::secret value in ${f}"; BAD=1
    done < <(grep -RlF -f "${PATTERNS}" -- "${DIR}" || true)
fi
exit "${BAD}"
