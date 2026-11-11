#!/usr/bin/env bash
# Runs pgJDBC's own test suite (:postgresql:test) for one leg. Called in the runner container by
# pgsql/lib/run-suite.sh with the leg's PG* settings, LEG, CLIENT_TLS and BACKEND_TLS (empty for direct
# legs). Settings go into the properties files pgJDBC's tests read; its sources are not changed.
set -uo pipefail
cd /opt/pgjdbc || exit 1

# secondaries (multi-host tests): the two replicas in direct legs; ProxySQL itself in proxy legs
S1=5433 S2=5434
if [[ -n ${BACKEND_TLS:-} ]]; then S1=${PGPORT} S2=${PGPORT}; fi
{
    echo "test.url.PGHOST=${PGHOST}"
    echo "test.url.PGPORT=${PGPORT}"
    echo "test.url.PGDBNAME=test"
    echo "user=test"
    echo "password=test"
    echo "privilegedUser=postgres"
    echo "privilegedPassword=postgres"
    echo "secondaryServer1=${PGHOST}"
    echo "secondaryPort1=${S1}"
    echo "secondaryServer2=${PGHOST}"
    echo "secondaryPort2=${S2}"
    # test.url.* settings go into every test's URL and override what a test sets itself (pgJDBC's
    # Driver.parseURL: URL first). TLS legs therefore set no sslmode: pgJDBC's default (prefer) uses TLS,
    # as PostgreSQL and ProxySQL both offer it, and each SSL test keeps its own sslmode. Plain legs
    # force sslmode=disable (pgJDBC's SSL tests are off there).
    if [[ ${CLIENT_TLS} != 1 ]]; then
        echo "test.url.sslmode=disable"
    fi
} > build.local.properties
if [[ ${CLIENT_TLS} == 1 ]]; then
    printf 'certdir=certdir\nenable_ssl_tests=true\n' > ssltest.local.properties
else
    rm -f ssltest.local.properties
fi
echo "=== pgJDBC $(git rev-parse HEAD 2>/dev/null) leg ${LEG}: ${PGHOST}:${PGPORT}, client TLS ${CLIENT_TLS}"
cat build.local.properties

exec ./gradlew --no-daemon --console plain --warning-mode=none --init-script /opt/suite/init.gradle :postgresql:test
