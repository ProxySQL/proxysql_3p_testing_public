# PostgreSQL 3rd-party tests

This folder holds a pipeline that will run the original test suites of PostgreSQL drivers (pgJDBC,
psycopg, pgx and others) through ProxySQL and directly against PostgreSQL, and compare the results.
It runs on GitHub Actions in this repository and does not depend on any private scripts.

It is separate from the existing MySQL/legacy pipeline (`CI-3p.yml`, `3p-build.yml`, `3p-suite.yml`),
which is not changed. The PostgreSQL suites that the legacy pipeline runs keep running until this
pipeline has a replacement for each of them.

**Status: stage 3.** The pipeline builds ProxySQL and runs the first test suite, pgJDBC, unmodified,
directly against PostgreSQL and through ProxySQL, with and without TLS. Each leg's JUnit results and
logs are kept. Comparing the results and reports come next (see [What comes next](#what-comes-next)).

## What stage 1 adds

| File | Purpose |
|---|---|
| `.github/workflows/pgsql-3p.yml` | The workflow you start, shown in GitHub as **PostgreSQL 3rd-party tests** |
| `.github/workflows/pgsql-3p-build.yml` | Builds ProxySQL and packages it as a Docker image; called by `pgsql-3p.yml` |
| `pgsql/versions.env` | Pinned Docker images (Ubuntu base image, PostgreSQL 18.6), each by exact digest |
| `pgsql/docker/proxysql/Dockerfile` | The ProxySQL runtime image |
| `pgsql/lib/resolve-ref.sh` | Turns a branch name into one exact commit |
| `pgsql/lib/package-image.sh` | Builds the runtime image from the ProxySQL `.deb` and saves it to a file |
| `pgsql/lib/check-version.sh` | Checks the image contains ProxySQL 4.0 built from the expected commit |
| `pgsql/lib/load-image.sh` | Loads the saved image in another job and checks it is the same image |
| `pgsql/lib/tests/` | Tests for the scripts above |

## What stage 2 adds

| File | Purpose |
|---|---|
| `pgsql/docker/compose.yml` | The test environment of one leg: PostgreSQL, ProxySQL (proxy legs only) and a `psql` client |
| `pgsql/docker/postgres/pg_hba.conf` | PostgreSQL login rules, the same in every leg |
| `pgsql/docker/proxysql/proxysql.cnf` | ProxySQL start-up config: only the data directory, everything else at ProxySQL's defaults |
| `pgsql/lib/certs.sh` | Creates a test certificate authority and one server certificate per job |
| `pgsql/lib/leg-up.sh` | Starts one leg, prepares PostgreSQL, configures ProxySQL, proves the connection and TLS |
| `pgsql/lib/prove-tls.sh` | The connection and TLS proof used by `leg-up.sh` |
| `pgsql/lib/leg-down.sh` | Saves the leg's logs and container state, then removes its containers |
| `pgsql/lib/guard-artifacts.sh` | Stops an upload that contains a private key or a password (text, binary or symlinked files) |
| `pgsql/lib/legs-summary.sh` | Writes the per-leg table of the run page summary |
| `pgsql/lib/tests/` | Tests for the scripts above (`test-certs.sh`, `test-guard.sh`, `test-legs-summary.sh`, `test-legs.sh`) |

The workflows only call the scripts, so everything except the real ProxySQL build can be tested on a
developer machine.

## What stage 3 adds

| File | Purpose |
|---|---|
| `pgsql/suites/<suite>/` | One folder per test suite (see [Adding a suite](#adding-a-suite)); the first is `pgjdbc` |
| `pgsql/lib/fetch-suite.sh` | Downloads a suite's upstream tests at its pinned commit, and refuses any other commit |
| `pgsql/lib/run-suite.sh` | Runs one suite in each leg: tests, time limit, outcome, test counts, `metadata.json` |
| `pgsql/lib/junit-counts.py` | Adds up the tests, failures, errors and skips of a leg's JUnit files |
| `pgsql/lib/tests/fixtures/` | A minimal suite and sample JUnit files used by the tests |

## How a run works

```
Run workflow (proxysql_ref = v3.0)
  │
  ├─ resolve      v3.0 → exact commit of sysown/proxysql (only this commit is used from here on)
  │
  ├─ build        compile ProxySQL 4.0 at that commit → .deb → Docker image
  │               check: version is 4.0.x and matches the commit
  │               upload: image file + build log
  │
  └─ suite / <suite>   one job per suite, in parallel
                       download and load the image; check: same image ID, version and commit
                       get the suite's upstream tests at their pinned commit, build its test runner
                       for each leg: start → prove → run the tests → save results and logs → stop
```

1. **resolve** looks up the newest commit of the branch you gave (default `v3.0`) in
   `sysown/proxysql`. If you give a full 40-character commit instead, it uses that commit as is. From
   this point only the commit is passed on, so the tested code cannot change in the middle of a run.
2. **build** checks out that commit and runs `PROXYSQL40=1 WITHGCOV=1 make ubuntu24-dbg`: ProxySQL 4.0,
   debug build, with code-coverage instrumentation, the same build the legacy pipeline uses. This is
   the slow part of a run; the job is stopped after 180 minutes. The `.deb` package it produces is
   installed into a Docker image based on the pinned `ubuntu:24.04` image. That image build has no
   network access and downloads nothing: the image is exactly the pinned base image plus the ProxySQL
   package, whose only dependency (`libgnutls30`) is already in the base image. The job then checks that
   `proxysql --version` inside the image is `4.0.x` and contains the first 7 characters of the commit,
   and uploads the image and the build log.
3. **suite** runs once per suite, each on its own machine; one suite failing does not stop the
   others. It downloads the image, loads it, and fails if its image ID, version or commit differ from
   what the build reported. It downloads the suite's original tests at the exact pinned commit, builds
   the suite's test runner, and then runs the tests once per leg (see
   [How a leg works](#how-a-leg-works)). Its summary on the run page shows the image and, per leg, the
   outcome and the number of tests, failures, errors and skipped tests. The job turns red only when the
   suite or a leg could not be set up; failing tests are results, not job failures.

## How a leg works

A **leg** is one way of connecting to the database. Each test suite will run once per leg, so the
results can be compared: the direct legs are the reference, the proxy legs show what changes through
ProxySQL.

| Leg | The client connects to | Client TLS | ProxySQL → PostgreSQL TLS | Run by the workflow |
|---|---|---|---|---|
| `direct-plain` | PostgreSQL (`pg:5432`) | no | - | yes |
| `direct-tls` | PostgreSQL (`pg:5432`) | yes | - | yes |
| `proxy-plain` | ProxySQL (`proxysql:6133`) | no | no | yes |
| `proxy-tls` | ProxySQL (`proxysql:6133`) | yes | yes | yes |
| `proxy-tls-front` | ProxySQL (`proxysql:6133`) | yes | no | not yet |
| `proxy-tls-back` | ProxySQL (`proxysql:6133`) | no | yes | not yet |

```
leg-up.sh   start PostgreSQL 18.6 (TLS always on) ─┐
            [proxy legs] start ProxySQL, configure  │ any failure here: status infra_failure
            prove the connection and TLS          ──┘ with the step that failed as the reason
            → artifacts/leg.json: status "ready"
   ... (stage 3: the test suite runs here) ...
leg-down.sh save logs and container state, remove containers, networks and volumes
```

Every leg starts from new containers, so nothing carries over from one leg to the next.

After a leg is ready, the suite's tests run in its runner container, with the suite's time limit.
The leg's outcome is then one of:

| Outcome | Meaning |
|---|---|
| `completed` | The tests ran to the end and left JUnit results (failing tests included) |
| `timed_out` | The suite's time limit was reached; the results written until then are kept |
| `no_results` | The tests ended without any JUnit results |
| `proxysql_crashed` | ProxySQL stopped or restarted while the tests ran (a ProxySQL problem, not a setup one) |
| `infra_failure` | The leg could not be set up (see the reason), so no tests ran | Each step has
a time limit (PostgreSQL healthy within 120 seconds, ProxySQL's admin port within 60 seconds, the proof
within 30 seconds, each connection attempt 10 seconds), so a hanging ProxySQL makes the leg fail
instead of blocking the job. `leg-down.sh` removes every container of the leg, including one-off
containers started with `docker compose run`.

**TLS.** PostgreSQL always accepts TLS, and ProxySQL always accepts TLS from clients (its default), in
every leg. Each side is then decided per leg:

- **Client to the endpoint:** the client is told to use `sslmode=disable` (no TLS) or
  `sslmode=verify-full` (TLS, certificate and host name checked against the test CA).
- **ProxySQL to PostgreSQL:** decided by `use_ssl` on ProxySQL's server row: `0` is no TLS, `1` is
  TLS. With TLS, ProxySQL encrypts but does not verify PostgreSQL's certificate (its default).

The proof connects with the leg's client setting and asks PostgreSQL whether the connection it sees
is encrypted (`pg_stat_ssl`). For direct legs, that is the client's own connection. For proxy legs,
it is ProxySQL's connection to PostgreSQL. A leg whose TLS is not what it should be on either side
does not count as ready. A test certificate authority is created once per job; PostgreSQL and ProxySQL
use the same server certificate, valid for `pg`, `proxysql`, `localhost` and `127.0.0.1`.

**In suite mode** (`run-suite.sh` passes the suite folder), a leg uses the suite's own PostgreSQL
setup (its `compose.yml`), registers the suite's users in ProxySQL instead of the `pgsql3p` user, and,
for suites with `NETWORK_MODE=shared`, runs the proof and the tests in the target's network, so they
connect to `localhost` (needed when a suite's certificate is only valid for `localhost`).

**ProxySQL settings.** ProxySQL runs with its default settings. Per leg, only what the setup needs is
changed, through the admin interface:

- one user in `pgsql_users` (with `fast_forward=0`, so ProxySQL handles the protocol itself);
- one server in `pgsql_servers`: `pg:5432` in hostgroup 0, with `use_ssl` as above;
- `pgsql-server_version` set to the real PostgreSQL version, because ProxySQL's default (`16.1`) would
  mislead drivers about what the server supports.

The admin interface is reached with `psql` over ProxySQL's PostgreSQL admin port (6132), from a
container that shares ProxySQL's network, because the default `admin` login is only accepted from
`127.0.0.1`. So the ProxySQL image needs no extra client.

Nothing else is changed. ProxySQL's health checks use their default login, `monitor` / `monitor`, so
that user is created in PostgreSQL instead. The tests focus on ProxySQL's **native** PostgreSQL backend
protocol, which is on by default in this build (`pgsql-use_native_backend_protocol`). Each proxy leg
checks that it is on, and is not ready otherwise. Each proxy leg also saves ProxySQL's resulting
configuration (passwords masked) and its SHA-256 fingerprint, so runs with a different configuration
can be told apart.

Every job runs on a fresh GitHub-hosted `ubuntu-24.04` machine.

## Running it

The workflow only runs when started by hand. It never starts on its own, on pushes or on pull requests.

1. Open the repository on GitHub and go to **Actions**.
2. Select **PostgreSQL 3rd-party tests** on the left.
3. Click **Run workflow**, keep or change the inputs, and click the green **Run workflow** button.

| Input | Default | Meaning |
|---|---|---|
| `proxysql_ref` | `v3.0` | A `sysown/proxysql` branch name, or a full, lowercase 40-character commit (no short commits or tags) |
| `suites` | all | Comma-separated suite names (folders in `pgsql/suites/`), for example `pgjdbc` |
| `tls` | `standard` | `standard`: the four standard legs; `full`: also the two legs with TLS on one side only |
| `retention_days` | 30 | How long the suite artifacts are kept, 1 to 90 days (default from the repository variable `PGSQL_3P_RETENTION_DAYS` if set) |

From the command line: `gh workflow run pgsql-3p.yml -f proxysql_ref=v3.0 -f suites=pgjdbc`.

To run a version of the workflow from another branch of this repository (for example, to try a change
before merging), choose that branch in the **Use workflow from** list, or add `--ref <branch>` to the
`gh` command. This works once `pgsql-3p.yml` exists on `main`.

Several runs can go at the same time, for example to test several ProxySQL commits.

## Results and downloads

Open a run from the **Actions** tab. The page shows each job with its steps and logs, the summary of
each suite job (ProxySQL version and image ID, and one row per leg with its outcome and test counts),
and an **Artifacts** section at the bottom with the files the run produced:

| Artifact | Contents | Kept for |
|---|---|---|
| `pgsql-3p-proxysql-image-<commit>` | `proxysql-image.tar.zst`, the ProxySQL runtime image | 3 days |
| `pgsql-3p-build-log-<commit>-attempt<n>` | `build.log`, the full build output (one per attempt, so a re-run keeps the earlier log) | 7 days |
| `pgsql-3p-<suite>-<commit7>-r<run>-a<attempt>` | One per suite: `metadata.json`, `runner-build.log`, and `legs/<leg>/` with the files below | `retention_days` (30) |

`metadata.json` records what was tested with what: the ProxySQL commit, version and image, the
PostgreSQL image, the suite's upstream repository, tag and verified commit, the runner image, this
repository's commit, the GitHub runner image, the Docker version, start and end times, and each leg's
TLS settings, outcome and test counts. If the suite could not start, `suite-status.json` says why.

Each leg folder (`legs/<leg>/`) holds:

| File | Contents |
|---|---|
| `leg.json` | Leg name, TLS settings, outcome and reason, start and end time, images, PostgreSQL version, backend protocol, ProxySQL config fingerprint, the runner's exit code and the test counts |
| `junit/` | The suite's JUnit XML results, as the suite wrote them |
| `upstream-html/` | The suite's own HTML report, if it makes one |
| `test-output.log` | Everything the test runner printed |
| `tls-proof.txt` | The result of the connection and TLS proof |
| `postgresql.log`, `proxysql.log` | Container logs, with timestamps |
| `postgresql-settings.txt` | PostgreSQL's settings (`SHOW ALL`) |
| `proxysql-config.txt` | ProxySQL's PostgreSQL variables, servers and users (passwords masked); proxy legs only |
| `containers.json` | Each container's final state: status, exit code, restarts, out-of-memory |
| `cert-metadata.txt` | The test certificates' subject, names, validity and fingerprints (no keys) |

Private keys, passwords and connection settings stay on the machine that ran the job. Before the
upload, a check scans every file for private keys and for the passwords the job generated, and the
upload is skipped if it finds one.

Click an artifact's name to download it as a zip file, or use
`gh run download <run-id> -n <artifact-name>`.

To use the downloaded image on your own machine:

```bash
unzip pgsql-3p-proxysql-image-<commit>.zip
zstd -dc proxysql-image.tar.zst | docker load
docker run --rm --entrypoint proxysql pgsql-3p-proxysql:<commit> --version
```

## Suites

### Adding a suite

A suite is a folder `pgsql/suites/<name>/`. Adding the folder is enough: the workflow finds it.

| File | Required | Contents |
|---|---|---|
| `suite.env` | yes | `UPSTREAM_REPO`, `UPSTREAM_REF` (tag), `UPSTREAM_SHA` (the exact commit; any other commit is refused), `PROXYSQL_USERS` (`user:password` pairs the tests log in with; the first is used for the connection proof), `SUITE_DATABASE`, `NETWORK_MODE` (`shared` if the tests must connect to `localhost`), `LEG_TIMEOUT_MINUTES` |
| `Dockerfile` | yes | The test runner image. Build context: the upstream checkout; the suite folder is available as the build context `suite`. Base images pinned by digest (see `pgsql/versions.env`) |
| `run.sh` | yes | Runs inside the runner for each leg. Gets `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE`, `PGCONNECT_TIMEOUT`, `LEG`, `CLIENT_TLS` (`0`/`1`) and `BACKEND_TLS` (empty for direct legs). Writes JUnit XML to `/results/junit/` |
| `compose.yml` | yes | Adds the `runner` service (and, if the suite needs one, its own PostgreSQL setup) on top of `pgsql/docker/compose.yml`. Variables it can use: `UPSTREAM_DIR`, `SUITE_WORK`, `RUNNER_IMAGE`, `LEG_RESULTS_DIR`, `LEG_TARGET` |
| `prepare.sh` | no | Runs once per job with the upstream checkout, the certificate folder and `SUITE_WORK`; makes the certificates (default: a new test CA) and any other files the suite needs |
| `README.md` | yes | What the suite covers, how it is set up, how to update its pin |

Rules: the upstream checkout is never edited, and no upstream test is removed or disabled. Settings go
only into files or options the upstream tests themselves read.

### pgJDBC

`pgsql/suites/pgjdbc/` runs pgJDBC's own test suite (`./gradlew :postgresql:test`, about 9,000 tests,
more with TLS) at `REL42.7.14`. See its [README](suites/pgjdbc/README.md).

## When a run fails

| Message | Meaning |
|---|---|
| `invalid ref '...'` or `branch '...' not found` | `proxysql_ref` is not an existing branch or a full 40-character commit |
| The build step fails | ProxySQL did not compile; download the build log artifact |
| `not a v4.0 build: '...'` | The build did not produce ProxySQL 4.0 (for example, a changed Makefile flag) |
| `version '...' is not commit ...` | The binary was not built from the requested commit |
| `expected exactly one proxysql_*.deb in ...` | The build produced no package, or more than one |
| `docker build of ... failed after 3 attempts` | The runtime image could not be built, 3 times in a row. The image build downloads nothing (it runs without network access), so look for a problem with the base image or the `.deb` in the step's log |
| `image ... has ID ..., expected ...` | A job loaded a different image than the build produced (wrong or stale artifact); re-run the whole workflow |
| `legs not ready: ...` | At least one leg's setup failed; the summary table and that leg's `leg.json` give the step and the reason |
| `<leg>: infra_failure: start postgresql: ...` | PostgreSQL did not start or did not become healthy within 120 seconds; see `postgresql.log` |
| `<leg>: infra_failure: start proxysql: ...` | The ProxySQL container did not start, or its admin port was not reachable within 60 seconds; see `proxysql.log` |
| `... use_native_backend_protocol is '...', expected 'true'` | The build does not use the native backend protocol by default (for example, a changed build flag) |
| `... pg_stat_ssl.ssl is 't', expected 'f'` (or the reverse) | TLS on one side is not what the leg requires |
| `private key in ...` / `secret value in ...` | The upload check found a key or a password in a leg's files; nothing was uploaded |
| `Suite could not start: fetching ... failed` | The suite's upstream tests could not be downloaded at its tag |
| `... is commit ..., expected ... (moved or rewritten tag?)` | The upstream tag now points to a different commit; the suite's pin must be checked and updated on purpose |
| `Suite could not start: building the runner image failed 3 times` | The suite's test runner could not be built (often a dependency download); see `runner-build.log` in the artifact |
| A leg `timed_out` | The suite's time limit was reached; `test-output.log` shows the last test that ran |
| A leg `proxysql_crashed` | ProxySQL stopped or restarted during the tests; see `proxysql.log` and `containers.json` |

## Testing the scripts locally

```bash
bash pgsql/lib/tests/test-resolve-ref.sh   # needs network access to github.com
bash pgsql/lib/tests/test-image.sh         # needs docker, dpkg-deb, zstd and network access; a few minutes
```

`test-image.sh` uses small fake ProxySQL packages instead of the real build, so it checks the scripts'
behaviour (version and commit checks, package selection, image size, image ID checks, retrying a
failed image build), not ProxySQL.

```bash
bash pgsql/lib/tests/test-certs.sh          # needs openssl
bash pgsql/lib/tests/test-guard.sh          # needs openssl
bash pgsql/lib/tests/test-legs-summary.sh   # needs jq
PROXYSQL_IMAGE=pgsql-3p-proxysql:<commit> bash pgsql/lib/tests/test-legs.sh   # docker, jq; about 5 minutes
```

```bash
bash pgsql/lib/tests/test-fetch-suite.sh    # git only
bash pgsql/lib/tests/test-junit-counts.sh   # python3, jq
PROXYSQL_IMAGE=pgsql-3p-proxysql:<commit> bash pgsql/lib/tests/test-run-suite.sh   # docker; a few minutes
```

`test-run-suite.sh` runs a minimal suite and checks each outcome (`completed`, `timed_out`,
`proxysql_crashed`, `no_results`), the test counts, `metadata.json` and the cleanup.

To run a real suite on your machine, with any legs:

```bash
PROXYSQL_IMAGE=pgsql-3p-proxysql:<commit> bash pgsql/lib/run-suite.sh pgjdbc /tmp/pgjdbc-run direct-plain proxy-plain
```

`test-legs.sh` brings up all six legs with a real ProxySQL image, checks each one, and also checks
that a wrong TLS expectation fails, that the proof gives up quickly when ProxySQL hangs, that a
missing image is reported as an `infra_failure`, and that nothing is left behind (not even a one-off
container). To get the image of a run (kept for 3 days):

```bash
gh run download <run-id> -R ProxySQL/proxysql_3p_testing_public -n pgsql-3p-proxysql-image-<commit>
zstd -dc proxysql-image.tar.zst | docker load
```

To bring up one leg by hand and look around:

```bash
bash pgsql/lib/certs.sh /tmp/pgsql3p-certs
CERT_DIR=/tmp/pgsql3p-certs PROXYSQL_IMAGE=pgsql-3p-proxysql:<commit> bash pgsql/lib/leg-up.sh proxy-tls /tmp/leg
docker compose --env-file /tmp/leg/compose.env run --rm admin -h 127.0.0.1 -p 6132 -U admin -d admin
bash pgsql/lib/leg-down.sh /tmp/leg
```

## Updating the pinned images

`pgsql/versions.env` pins each image by digest, so every run uses exactly the same image. To move to a
newer image, look up its digest and replace the whole value, for example:

```bash
docker buildx imagetools inspect postgres:18.6-trixie | grep -m1 '^Digest:'
```

Write the value as `<image>:<tag>@<digest>` and update the date comment in the file.

## What comes next

Each stage is added on top of this one, and this file is extended with it:

2. ~~The test environment: PostgreSQL 18.6 and ProxySQL started in Docker, with and without TLS.~~
   Done.
3. ~~The first test suite, pgJDBC, run directly against PostgreSQL and through ProxySQL.~~ Done.
4. Per-suite reports: passed, failed, skipped and errored tests, and the list of tests that pass on
   PostgreSQL but fail through ProxySQL.
5. Comparison with earlier runs (new failures, fixed tests, flaky tests).
6. Complete documentation, followed by more test suites, one at a time.
