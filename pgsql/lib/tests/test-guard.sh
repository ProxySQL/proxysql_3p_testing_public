#!/usr/bin/env bash
# shellcheck disable=SC2015  # pass() always succeeds, so "cond && pass || fail" is a safe if/else
# Tests for pgsql/lib/guard-artifacts.sh. Needs openssl (to make a real private key).
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

SECRETS="${TMP}/secrets"
printf 's3cr3t-value\n' > "${SECRETS}"

# guard DIR SECRETS_FILE -> sets OUT and RC
guard() { OUT=$(bash "${LIB}/guard-artifacts.sh" "$1" "$2" 2>&1); RC=$?; }

mkdir -p "${TMP}/clean/sub"; echo "plain log line" > "${TMP}/clean/sub/a.log"
guard "${TMP}/clean" "${SECRETS}"
[[ ${RC} -eq 0 ]] && pass "clean directory passes" || fail "clean (rc=${RC}: ${OUT})"

mkdir -p "${TMP}/key"; openssl genrsa 2048 2>/dev/null > "${TMP}/key/leak.pem"
guard "${TMP}/key" "${SECRETS}"
[[ ${RC} -eq 1 && ${OUT} == *leak.pem* ]] && pass "private key is detected and the file named" \
    || fail "key (rc=${RC}: ${OUT})"

mkdir -p "${TMP}/pw"; echo "connecting with password s3cr3t-value" > "${TMP}/pw/app.log"
guard "${TMP}/pw" "${SECRETS}"
[[ ${RC} -eq 1 && ${OUT} == *app.log* && ${OUT} != *s3cr3t-value* ]] \
    && pass "secret value is detected, file named, value not printed" || fail "secret (rc=${RC}: ${OUT})"

mkdir -p "${TMP}/bin"; { printf 'log\0'; openssl genrsa 2048 2>/dev/null; } > "${TMP}/bin/output.bin"
guard "${TMP}/bin" "${SECRETS}"
[[ ${RC} -eq 1 && ${OUT} == *output.bin* ]] && pass "private key after a NUL byte (binary file) is detected" \
    || fail "binary file (rc=${RC}: ${OUT})"

mkdir -p "${TMP}/outside" "${TMP}/link"; openssl genrsa 2048 2>/dev/null > "${TMP}/outside/key.pem"
ln -s "${TMP}/outside/key.pem" "${TMP}/link/key-link.pem"
guard "${TMP}/link" "${SECRETS}"
[[ ${RC} -eq 1 && ${OUT} == *key-link.pem* ]] && pass "private key behind a symlink is detected" \
    || fail "symlink (rc=${RC}: ${OUT})"

printf '\nother-secret\n\n' > "${TMP}/secrets-empty-lines"
guard "${TMP}/clean" "${TMP}/secrets-empty-lines"
[[ ${RC} -eq 0 ]] && pass "empty lines in the secrets file are ignored" || fail "empty lines (rc=${RC}: ${OUT})"

guard "${TMP}/clean" "${TMP}/no-such-file"
[[ ${RC} -eq 1 ]] && pass "missing secrets file fails" || fail "missing secrets file (rc=${RC})"

exit "${FAILED}"
