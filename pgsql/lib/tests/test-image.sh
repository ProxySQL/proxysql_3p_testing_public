#!/usr/bin/env bash
# pass() always succeeds, so "cond && pass || fail" is a safe if/else here
# shellcheck disable=SC2015
# Tests for package-image.sh, check-version.sh and load-image.sh, using fake ProxySQL .deb packages.
# Needs docker, dpkg-deb, zstd and network access (base image, apt).
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
TAGS=()
FAILED=0

# shellcheck disable=SC2317  # called by the EXIT trap
cleanup() {
    for t in "${TAGS[@]}"; do docker rmi -f "${t}" >/dev/null 2>&1; done
    rm -rf "${TMP}"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# make_deb OUT_DIR FILE_NAME VERSION_STRING [PAYLOAD_MIB]: fake package 'proxysql' whose /usr/bin/proxysql
# prints a log line (as the real binary does) and then 'ProxySQL version <VERSION_STRING>, codename Truls';
# PAYLOAD_MIB adds an incompressible file of that size
make_deb() {
    local root="${TMP}/pkg-$RANDOM"
    mkdir -p "${root}/DEBIAN" "${root}/usr/bin" "${root}/usr/share/proxysql" "$1"
    if [[ -n ${4:-} ]]; then head -c "$(( $4 * 1024 * 1024 ))" /dev/urandom > "${root}/usr/share/proxysql/payload"; fi
    printf 'Package: proxysql\nVersion: 4.0.1\nArchitecture: amd64\nMaintainer: test <test@example.invalid>\nDescription: fake proxysql for tests\n' > "${root}/DEBIAN/control"
    cat > "${root}/usr/bin/proxysql" <<EOF
#!/bin/sh
echo "2026-11-11 10:29:21 main.cpp:390:check_openssl_version(): [INFO] Using OpenSSL version: OpenSSL 3.5.7" >&2
echo "ProxySQL version $3, codename Truls"
EOF
    chmod 0755 "${root}/usr/bin/proxysql"
    dpkg-deb --build --root-owner-group "${root}" "$1/$2" >/dev/null
}

SHA_OK=abcdef1000000000000000000000000000000000
SHA_OTHER=1234567000000000000000000000000000000000

# --- 4.0 package: package, version check, wrong commit
make_deb "${TMP}/b40" proxysql_4.0.1_amd64.deb "4.0.1-12-gabcdef1_DEBUG"
TAG40="pgsql-3p-proxysql-test:40-$$"; TAGS+=("${TAG40}")
OUT=$(bash "${LIB}/package-image.sh" "${TMP}/b40" "${TAG40}" "${TMP}/img40.tar.zst" 2>"${TMP}/pkg40.err"); RC=$?
ID40=$(tail -n1 <<< "${OUT}")
if [[ ${RC} -eq 0 && ${ID40} =~ ^sha256:[0-9a-f]{64}$ && -s ${TMP}/img40.tar.zst ]]; then
    pass "package-image prints the image ID and writes the archive"
else
    fail "package-image 4.0 (rc=${RC}, last line='${ID40}', stderr: $(tail -n5 "${TMP}/pkg40.err"))"
fi

OUT=$(bash "${LIB}/check-version.sh" "${TAG40}" "${SHA_OK}" 2>/dev/null); RC=$?
[[ ${RC} -eq 0 && ${OUT} == "4.0.1-12-gabcdef1_DEBUG" ]] && pass "check-version accepts 4.0 of this commit (log line before version)" \
    || fail "check-version 4.0 (rc=${RC}, out='${OUT}')"

ERR=$(bash "${LIB}/check-version.sh" "${TAG40}" "${SHA_OTHER}" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && ${ERR} == *"is not commit 1234567"* ]] && pass "check-version rejects another commit" \
    || fail "check-version wrong commit (rc=${RC}, err='${ERR}')"

for BAD in "" "abcdef1"; do
    ERR=$(bash "${LIB}/check-version.sh" "${TAG40}" "${BAD}" 2>&1 >/dev/null); RC=$?
    [[ ${RC} -eq 1 && ${ERR} == *"full 40-hex"* ]] && pass "check-version rejects sha '${BAD}' (not a full commit)" \
        || fail "check-version sha '${BAD}' (rc=${RC}, err='${ERR}')"
done

# --- the package is installed, not also kept as an image layer: a 16 MiB payload adds ~16 MiB, not ~32
make_deb "${TMP}/big" proxysql_4.0.1_amd64.deb "4.0.1-12-gabcdef1_DEBUG" 16
TAGB="pgsql-3p-proxysql-test:big-$$"; TAGS+=("${TAGB}")
bash "${LIB}/package-image.sh" "${TMP}/big" "${TAGB}" "${TMP}/imgb.tar.zst" >/dev/null 2>&1
GROWTH=$(( $(stat -c %s "${TMP}/imgb.tar.zst") - $(stat -c %s "${TMP}/img40.tar.zst") ))
(( GROWTH > 15 * 1024 * 1024 && GROWTH < 24 * 1024 * 1024 )) && pass "package is stored once in the image" \
    || fail "image grew by ${GROWTH} bytes for a 16 MiB package payload (expected 15-24 MiB)"

# --- 3.1 package: not a 4.0 build
make_deb "${TMP}/b31" proxysql_3.1.12_amd64.deb "3.1.12-1802-gabcdef1_DEBUG"
TAG31="pgsql-3p-proxysql-test:31-$$"; TAGS+=("${TAG31}")
bash "${LIB}/package-image.sh" "${TMP}/b31" "${TAG31}" "${TMP}/img31.tar.zst" >/dev/null 2>&1
ERR=$(bash "${LIB}/check-version.sh" "${TAG31}" "${SHA_OK}" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && ${ERR} == *"not a v4.0 build: '3.1.12-1802-gabcdef1_DEBUG'"* ]] && pass "check-version rejects a 3.1 build" \
    || fail "check-version 3.1 (rc=${RC}, err='${ERR}')"

# --- package selection: none, two, one plus dbgsym
mkdir -p "${TMP}/none"
ERR=$(bash "${LIB}/package-image.sh" "${TMP}/none" "pgsql-3p-proxysql-test:none-$$" "${TMP}/x.tar.zst" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && ${ERR} == *"${TMP}/none"* && ${ERR} == *" 0 "* ]] && pass "package-image fails with no .deb" \
    || fail "package-image no deb (rc=${RC}, err='${ERR}')"

make_deb "${TMP}/two" proxysql_4.0.1_amd64.deb "4.0.1-12-gabcdef1_DEBUG"
make_deb "${TMP}/two" proxysql_4.0.2_amd64.deb "4.0.2-1-gabcdef1_DEBUG"
ERR=$(bash "${LIB}/package-image.sh" "${TMP}/two" "pgsql-3p-proxysql-test:two-$$" "${TMP}/x.tar.zst" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && ${ERR} == *"${TMP}/two"* && ${ERR} == *" 2 "* ]] && pass "package-image fails with two .deb files" \
    || fail "package-image two debs (rc=${RC}, err='${ERR}')"

make_deb "${TMP}/dbg" proxysql_4.0.1_amd64.deb "4.0.1-12-gabcdef1_DEBUG"
make_deb "${TMP}/dbg" proxysql_4.0.1-dbgsym_amd64.deb "unused"
TAGD="pgsql-3p-proxysql-test:dbg-$$"; TAGS+=("${TAGD}")
bash "${LIB}/package-image.sh" "${TMP}/dbg" "${TAGD}" "${TMP}/imgd.tar.zst" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 0 ]] && pass "package-image ignores dbgsym packages" || fail "package-image dbgsym (rc=${RC})"

# --- a failed docker build (e.g. DNS failure inside apt) is retried: a shim 'docker' fails the first N builds
REAL_DOCKER=$(command -v docker)
mkdir -p "${TMP}/shim"
# shellcheck disable=SC2016  # single quotes on purpose: this is the shim's own script text
printf '%s\n' '#!/bin/sh' \
    'if [ "$1" = build ]; then' \
    '    n=$(( $(cat "$SHIM_DIR/builds" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SHIM_DIR/builds"' \
    '    if [ "$n" -le "$(cat "$SHIM_DIR/fail")" ]; then echo "simulated build failure $n" >&2; exit 1; fi' \
    'fi' \
    'exec "$REAL_DOCKER" "$@"' > "${TMP}/shim/docker"
chmod +x "${TMP}/shim/docker"
export SHIM_DIR="${TMP}/shim" REAL_DOCKER

echo 1 > "${TMP}/shim/fail"; rm -f "${TMP}/shim/builds"
TAGR="pgsql-3p-proxysql-test:retry-$$"; TAGS+=("${TAGR}")
OUT=$(PATH="${TMP}/shim:${PATH}" PGSQL3P_RETRY_DELAY=1 bash "${LIB}/package-image.sh" "${TMP}/b40" "${TAGR}" "${TMP}/imgr.tar.zst" 2>/dev/null); RC=$?
[[ ${RC} -eq 0 && $(tail -n1 <<< "${OUT}") =~ ^sha256: && $(cat "${TMP}/shim/builds") -eq 2 ]] \
    && pass "package-image retries a failed docker build" || fail "retry once (rc=${RC}, builds=$(cat "${TMP}/shim/builds" 2>/dev/null))"

echo 99 > "${TMP}/shim/fail"; rm -f "${TMP}/shim/builds"
ERR=$(PATH="${TMP}/shim:${PATH}" PGSQL3P_RETRY_DELAY=1 bash "${LIB}/package-image.sh" "${TMP}/b40" "pgsql-3p-proxysql-test:never-$$" "${TMP}/x.tar.zst" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && $(cat "${TMP}/shim/builds") -eq 3 && ${ERR} == *"3 attempts"* ]] \
    && pass "package-image gives up after 3 attempts" || fail "retry exhausted (rc=${RC}, builds=$(cat "${TMP}/shim/builds" 2>/dev/null))"

# --- load-image: correct and wrong expected ID
docker rmi -f "${TAG40}" >/dev/null 2>&1
OUT=$(bash "${LIB}/load-image.sh" "${TMP}/img40.tar.zst" "${ID40}" 2>/dev/null); RC=$?
[[ ${RC} -eq 0 && $(tail -n1 <<< "${OUT}") == "${TAG40}" ]] && pass "load-image accepts the expected ID and prints the tag" \
    || fail "load-image right ID (rc=${RC}, out='${OUT}')"

ZERO="sha256:$(printf '0%.0s' {1..64})"
ERR=$(bash "${LIB}/load-image.sh" "${TMP}/img40.tar.zst" "${ZERO}" 2>&1 >/dev/null); RC=$?
[[ ${RC} -eq 1 && ${ERR} == *"${ZERO}"* && ${ERR} == *"${ID40}"* ]] && pass "load-image rejects a different ID and prints both" \
    || fail "load-image wrong ID (rc=${RC}, err='${ERR}')"

exit "${FAILED}"
