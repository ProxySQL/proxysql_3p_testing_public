#!/usr/bin/env bash
# Usage: certs.sh CERT_DIR
# Creates a test CA and one server certificate (used by both PostgreSQL and ProxySQL) in CERT_DIR:
# ca.pem, ca.key, server.pem, server.key and cert-metadata.txt (public details only, safe to upload).
# CERT_DIR must not exist or must be empty. The keys are test-only and must never be uploaded.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: certs.sh CERT_DIR"
DIR=$1
if [[ -e ${DIR} ]]; then
    [[ -d ${DIR} && -z $(ls -A "${DIR}") ]] || die "${DIR} exists and is not an empty directory"
fi
mkdir -p "${DIR}"
umask 077

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=pgsql-3p test CA" \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=pgsql-3p test server" \
    -keyout "${DIR}/server.key" -out "${DIR}/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:pg,DNS:proxysql,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > "${DIR}/server.ext"
openssl x509 -req -in "${DIR}/server.csr" -CA "${DIR}/ca.pem" -CAkey "${DIR}/ca.key" -CAcreateserial \
    -days 30 -extfile "${DIR}/server.ext" -out "${DIR}/server.pem" 2>/dev/null
rm -f "${DIR}/server.csr" "${DIR}/server.ext" "${DIR}/ca.srl"
chmod 0644 "${DIR}/ca.pem" "${DIR}/server.pem"

for c in ca server; do
    echo "== ${c}.pem"
    openssl x509 -in "${DIR}/${c}.pem" -noout -subject -issuer -dates -ext subjectAltName -fingerprint -sha256
done > "${DIR}/cert-metadata.txt"
chmod 0644 "${DIR}/cert-metadata.txt"
