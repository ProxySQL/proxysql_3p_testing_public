#!/usr/bin/env bash
# Usage: prepare.sh UPSTREAM_DIR CERT_DIR SUITE_WORK   (called once per job by pgsql/lib/run-suite.sh)
# - CERT_DIR: pgJDBC's own test server certificate, used by PostgreSQL and by ProxySQL, so pgJDBC's
#   certificate tests see the same certificate on both paths (server.pem, server.key, ca.pem, metadata).
# - SUITE_WORK/certdir-server: a copy of pgJDBC's certdir/server (mounted as /custom/certdir by
#   compose.yml), with one infrastructure line added to the copy of its pg_hba.conf so ProxySQL's default
#   monitor login can reach PostgreSQL. The upstream checkout itself is not changed.
set -euo pipefail

[[ $# -eq 3 ]] || { echo "::error::usage: prepare.sh UPSTREAM_DIR CERT_DIR SUITE_WORK" >&2; exit 1; }
UP=$1 CERT_DIR=$2 WORK=$3
SRV="${UP}/certdir/server"

mkdir -p "${CERT_DIR}"
install -m 0644 "${SRV}/server.crt" "${CERT_DIR}/server.pem"
install -m 0600 "${SRV}/server.key" "${CERT_DIR}/server.key"
install -m 0644 "${SRV}/root.crt" "${CERT_DIR}/ca.pem"
for c in ca server; do
    echo "== ${c}.pem"
    openssl x509 -in "${CERT_DIR}/${c}.pem" -noout -subject -issuer -dates -ext subjectAltName -fingerprint -sha256 2>/dev/null
done > "${CERT_DIR}/cert-metadata.txt"

mkdir -p "${WORK}"
cp -r "${SRV}" "${WORK}/certdir-server"
printf '\n# added by the PostgreSQL 3rd-party tests: ProxySQL health checks (default monitor login)\nhost    postgres    monitor    all    scram-sha-256\n' \
    >> "${WORK}/certdir-server/pg_hba.conf"
