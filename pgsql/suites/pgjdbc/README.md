# pgJDBC suite

Runs the test suite of [pgJDBC](https://github.com/pgjdbc/pgjdbc), the PostgreSQL JDBC driver, at
`REL42.7.14` (`ebdd9d0a4017e74182eabb0cc304105a0120b647`): the module's own `./gradlew :postgresql:test`,
the same tests pgJDBC's CI runs. pgJDBC implements the PostgreSQL protocol itself (it does not use
libpq), so it exercises ProxySQL's handling of the extended query protocol, prepared statements, COPY,
large objects, cancel requests, metadata queries and more.

Nothing in the pgJDBC checkout is edited or removed. All settings go into files pgJDBC's tests read
(`build.local.properties`, `ssltest.local.properties`) and a Gradle init script.

## Files

| File | Purpose |
|---|---|
| `suite.env` | The pinned upstream, ProxySQL users (`test`/`test`, `postgres`/`postgres`, pgJDBC's own test credentials), database `test`, shared network, 60-minute limit per leg |
| `prepare.sh` | Uses pgJDBC's test server certificate (`certdir/server`) for PostgreSQL and ProxySQL, and makes a copy of its `pg_hba.conf` with one added line for ProxySQL's health checks |
| `compose.yml` | PostgreSQL set up by pgJDBC's own `docker/postgres-server` scripts; the `runner` service |
| `Dockerfile` | The runner: pgJDBC's checkout on the pinned Temurin 21 JDK image, test classes compiled when the image is built |
| `init.gradle` | Per-test timeouts in a separate thread; results in the leg's results folder, also class by class while the tests run; the test task's own time limit |
| `run.sh` | Writes the leg's settings and runs `./gradlew :postgresql:test` |

## How it is set up

- **PostgreSQL:** pgJDBC's own server setup on the pinned PostgreSQL 18.6 image:
  - users `test` and `postgres`; databases `test`, `test_2`, `hostdb` and the SSL test databases;
  - the extensions `hstore` and `sslinfo`;
  - XA (`max_prepared_transactions`), SCRAM passwords and `wal_level=logical`;
  - two streaming replicas on ports 5433 and 5434;
  - its own certificates and `pg_hba.conf`.
  
  The same in every leg. The only addition is `host postgres monitor all scram-sha-256` in a copy of
  that `pg_hba.conf`, so ProxySQL's default `monitor` login can run its health checks.
- **Certificates:** pgJDBC's test server certificate is issued for `localhost` only. ProxySQL presents
  the same certificate, so pgJDBC's certificate tests see the same certificate whether they connect
  directly or through ProxySQL. Because of `localhost`, the runner shares the network of the leg's
  target: PostgreSQL in direct legs, ProxySQL in proxy legs.
- **Connection:** the tests connect to `localhost` on port 5432 (direct legs) or 6133 (ProxySQL).
  - Multi-host tests use the two replicas in direct legs. In proxy legs, both "secondary" servers are
    ProxySQL itself, because there is only one ProxySQL endpoint.
  - TLS legs turn on pgJDBC's own SSL tests (`enable_ssl_tests=true`) and set no `sslmode`:
    pgJDBC's default (`prefer`) uses TLS, because PostgreSQL and ProxySQL both offer it. A
    `test.url.sslmode` would go into every test's URL and override the mode each SSL test sets for
    itself.
  - Plain legs force `sslmode=disable`.
- **Hangs:** pgJDBC gives every test a 5-minute timeout. `init.gradle` makes JUnit enforce it in a
  separate thread, so a test blocked on a socket fails as a timeout and the suite carries on, instead
  of hanging until the leg's 60-minute limit. Known case: `CopyTest::lockReleaseOnCancelFailure`
  through ProxySQL.
- **Results of a stopped run:** Gradle writes its JUnit files (`TEST-<class>.xml`) only when the test
  task ends. `init.gradle` therefore also writes `PARTIAL-<class>.xml` as each test class finishes, and
  ends the test task 5 minutes before the leg's limit (`run.sh` then reports the leg as `timed_out`).
  When Gradle's own files are written, `run.sh` removes the partial ones; if the run was stopped, the
  partial files are the results. The partial files name each test exactly as Gradle's files do, so
  results of a stopped leg can be compared test by test with a complete one.

## Differences to expect through ProxySQL

Some tests cannot pass through any connection-pooling proxy, whatever ProxySQL does. They are run and
counted like every other test, never removed:

- logical and physical replication (`LogicalReplicationTest`, `PhysicalReplicationTest`,
  `ReplicationSlotTest`): ProxySQL does not proxy replication connections;
- multi-host tests that expect several servers with different roles: there is one ProxySQL endpoint;
- tests that create users or change passwords and then log in as them: ProxySQL only knows the users
  registered in it;
- SSL tests that rely on per-database `hostssl`/`hostnossl` rules or client certificates: TLS ends at
  ProxySQL, so PostgreSQL does not see the client's TLS or certificate.

## Updating the pin

1. Pick the new tag, for example `REL42.7.15`, and look up its commit:
   `git ls-remote https://github.com/pgjdbc/pgjdbc.git refs/tags/REL42.7.15`.
2. Set `UPSTREAM_REF` and `UPSTREAM_SHA` in `suite.env`.
3. Run the suite locally on a few legs (see `pgsql/README.md`, "Testing the scripts locally"), then
   in the workflow with `suites=pgjdbc`. Results from different pins are not comparable test by test.
