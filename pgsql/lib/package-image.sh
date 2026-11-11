#!/usr/bin/env bash
# Usage: package-image.sh BINARIES_DIR TAG OUT_FILE
# Builds the ProxySQL runtime image from the single proxysql_*.deb in BINARIES_DIR (dbgsym packages
# ignored), saves it zstd-compressed to OUT_FILE and prints the image ID as the last stdout line.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 3 ]] || die "usage: package-image.sh BINARIES_DIR TAG OUT_FILE"
BINARIES_DIR=$1 TAG=$2 OUT_FILE=$3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../versions.env
source "${HERE}/../versions.env"

DEBS=()
for f in "${BINARIES_DIR}"/proxysql_*.deb; do
    [[ -e ${f} && ${f} != *dbgsym* ]] && DEBS+=("${f}")
done
[[ ${#DEBS[@]} -eq 1 ]] || die "expected exactly one proxysql_*.deb in ${BINARIES_DIR}, found ${#DEBS[@]} ${DEBS[*]:-}"
echo "package: ${DEBS[0]}" >&2

CTX=$(mktemp -d)
trap 'rm -rf "${CTX}"' EXIT
cp "${HERE}/../docker/proxysql/Dockerfile" "${CTX}/Dockerfile"
cp "${DEBS[0]}" "${CTX}/proxysql.deb"

# --network=host: some developer machines' Docker build network has no egress for apt; harmless on runners
docker build --network=host --build-arg "UBUNTU_IMAGE=${UBUNTU_IMAGE}" -t "${TAG}" "${CTX}" >&2
docker save "${TAG}" | zstd -T0 -q -f -o "${OUT_FILE}"
docker image inspect -f '{{.Id}}' "${TAG}"
