#!/usr/bin/env bash
# Usage: fetch-suite.sh SUITE_DIR DEST
# Clones the suite's upstream tests (UPSTREAM_REPO at tag/branch UPSTREAM_REF, from SUITE_DIR/suite.env)
# into DEST and checks that they are exactly commit UPSTREAM_SHA, so a moved or rewritten tag can never
# silently change the tests. Prints the commit.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: fetch-suite.sh SUITE_DIR DEST"
SUITE_DIR=$1 DEST=$2
[[ -f ${SUITE_DIR}/suite.env ]] || die "no ${SUITE_DIR}/suite.env"
[[ ! -e ${DEST} ]] || die "${DEST} already exists"
UPSTREAM_REPO="" UPSTREAM_REF="" UPSTREAM_SHA=""
# shellcheck source=/dev/null
source "${SUITE_DIR}/suite.env"
[[ -n ${UPSTREAM_REPO} && -n ${UPSTREAM_REF} ]] || die "${SUITE_DIR}/suite.env needs UPSTREAM_REPO and UPSTREAM_REF"
[[ ${UPSTREAM_SHA} =~ ^[0-9a-f]{40}$ ]] || die "${SUITE_DIR}/suite.env: UPSTREAM_SHA must be a full 40-hex commit"

git -c advice.detachedHead=false clone -q --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_REPO}" "${DEST}" 2>/dev/null \
    || die "git clone of ${UPSTREAM_REPO} at ${UPSTREAM_REF} failed"
GOT=$(git -C "${DEST}" rev-parse HEAD)
[[ ${GOT} == "${UPSTREAM_SHA}" ]] \
    || die "${UPSTREAM_REPO} ${UPSTREAM_REF} is commit ${GOT}, expected ${UPSTREAM_SHA} (moved or rewritten tag?)"
echo "${GOT}"
