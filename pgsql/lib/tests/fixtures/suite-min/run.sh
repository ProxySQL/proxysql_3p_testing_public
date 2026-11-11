#!/usr/bin/env bash
# Runner of the minimal test suite. One "test": connect as the leg's user and check who we are.
# FIXTURE_MODE: normal | sleep (hang after writing results) | kill-proxysql | no-xml
set -u
mkdir -p /results/junit
MODE=${FIXTURE_MODE:-normal}
if [[ ${MODE} == no-xml ]]; then echo "no results on purpose"; exit 0; fi
OUT=$(psql -XtAc "SELECT current_user" 2>&1); RC=$?
FAILS=$([[ ${RC} -eq 0 && ${OUT} == "${PGUSER}" ]] && echo 0 || echo 1)
printf '<testsuite name="fixture" tests="1" failures="%s" errors="0" skipped="0"><testcase name="whoami" classname="fixture"/></testsuite>\n' \
    "${FAILS}" > /results/junit/TEST-fixture.xml
case ${MODE} in
    sleep) sleep 600 ;;
    kill-proxysql) env PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d admin -Xc 'PROXYSQL KILL' || true; sleep 3 ;;
esac
echo "fixture: ${LEG} ${OUT}"
