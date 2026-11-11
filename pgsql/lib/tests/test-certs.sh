#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/certs.sh. Needs openssl.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

C="${TMP}/c"
bash "${LIB}/certs.sh" "${C}" >/dev/null 2>"${TMP}/err"; RC=$?
[[ ${RC} -eq 0 ]] && pass "certs.sh succeeds on a new directory" || fail "certs.sh (rc=${RC}: $(cat "${TMP}/err"))"

openssl verify -CAfile "${C}/ca.pem" "${C}/server.pem" >/dev/null 2>&1 \
    && pass "server certificate is signed by the CA" || fail "openssl verify"

SAN=$(openssl x509 -in "${C}/server.pem" -noout -ext subjectAltName 2>/dev/null)
OK=1
for want in "DNS:pg" "DNS:proxysql" "DNS:localhost" "IP Address:127.0.0.1"; do
    [[ ${SAN} == *"${want}"* ]] || { OK=0; echo "  missing SAN ${want}"; }
done
[[ ${OK} -eq 1 ]] && pass "server certificate SAN covers pg, proxysql, localhost, 127.0.0.1" || fail "SAN: ${SAN}"

[[ $(stat -c %a "${C}/ca.key") == 600 && $(stat -c %a "${C}/server.key") == 600 ]] \
    && pass "private keys are mode 600" || fail "key modes: $(stat -c '%n %a' "${C}"/*.key)"

FP_CA=$(openssl x509 -in "${C}/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2)
FP_SRV=$(openssl x509 -in "${C}/server.pem" -noout -fingerprint -sha256 | cut -d= -f2)
META=$(cat "${C}/cert-metadata.txt" 2>/dev/null)
[[ -n ${FP_CA} && -n ${FP_SRV} && ${META} == *"${FP_CA}"* && ${META} == *"${FP_SRV}"* && ${META} != *"PRIVATE KEY"* ]] \
    && pass "cert-metadata.txt has both fingerprints and no key" || fail "cert-metadata.txt"

BEFORE=$(sha256sum "${C}/ca.pem")
bash "${LIB}/certs.sh" "${C}" >/dev/null 2>&1; RC=$?
[[ ${RC} -eq 1 && $(sha256sum "${C}/ca.pem") == "${BEFORE}" ]] \
    && pass "certs.sh refuses a non-empty directory and leaves it unchanged" || fail "second run (rc=${RC})"

exit "${FAILED}"
