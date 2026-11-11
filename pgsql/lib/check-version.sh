#!/usr/bin/env bash
# Usage: check-version.sh TAG SHA
# Prints the 'proxysql --version' of image TAG; fails unless it is a 4.0.x build of commit SHA.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: check-version.sh TAG SHA"
TAG=$1 SHA=$2
# a short or empty SHA would make the commit check below match any build
[[ ${SHA} =~ ^[0-9a-f]{40}$ ]] || die "invalid sha '${SHA}' (full 40-hex commit expected)"

OUT=$(docker run --rm --entrypoint proxysql "${TAG}" --version 2>&1) || die "proxysql --version failed in ${TAG}: ${OUT}"
VERSION=$(grep -m1 -oP 'ProxySQL version \K[^\s,]+' <<< "${OUT}") || die "no version in output of ${TAG}: ${OUT}"

[[ ${VERSION} =~ ^4\.0\. ]] || die "not a v4.0 build: '${VERSION}'"
[[ ${VERSION} == *-g${SHA:0:7}* ]] || die "version '${VERSION}' is not commit ${SHA:0:7}"
echo "${VERSION}"
