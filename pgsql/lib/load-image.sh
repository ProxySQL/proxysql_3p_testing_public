#!/usr/bin/env bash
# Usage: load-image.sh FILE EXPECTED_ID
# Loads the zstd-compressed image archive FILE and prints its tag; fails unless the loaded image's ID
# is EXPECTED_ID (the ID the build job reported), so every job tests exactly the same build.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: load-image.sh FILE EXPECTED_ID"
FILE=$1 EXPECTED_ID=$2

LOADED=$(zstd -dc "${FILE}" | docker load) || die "docker load of ${FILE} failed"
TAG=$(sed -n 's/^Loaded image: //p' <<< "${LOADED}" | head -n1)
[[ -n ${TAG} ]] || die "no tagged image in ${FILE}: ${LOADED}"

ID=$(docker image inspect -f '{{.Id}}' "${TAG}")
[[ ${ID} == "${EXPECTED_ID}" ]] || die "image ${TAG} has ID ${ID}, expected ${EXPECTED_ID} (wrong or stale artifact)"
echo "${TAG}"
