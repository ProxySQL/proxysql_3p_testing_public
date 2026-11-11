# PostgreSQL 3rd-party tests

This folder holds a pipeline that will run the original test suites of PostgreSQL drivers (pgJDBC,
psycopg, pgx and others) through ProxySQL and directly against PostgreSQL, and compare the results.
It runs on GitHub Actions in this repository and does not depend on any private scripts.

It is separate from the existing MySQL/legacy pipeline (`CI-3p.yml`, `3p-build.yml`, `3p-suite.yml`),
which is not changed. The PostgreSQL suites that the legacy pipeline runs keep running until this
pipeline has a replacement for each of them.

**Status: stage 2.** The pipeline builds ProxySQL, proves that every later job gets exactly that
build, and starts the test environment (PostgreSQL directly and through ProxySQL, with and without
TLS) on it. No test suites run yet; they are added in later stages (see
[What comes next](#what-comes-next)).

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
| `pgsql/lib/guard-artifacts.sh` | Stops an upload that contains a private key or a password |
| `pgsql/lib/tests/` | Tests for the scripts above (`test-certs.sh`, `test-guard.sh`, `test-legs.sh`) |

The workflows only call the scripts, so everything except the real ProxySQL build can be tested on a
developer machine.

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
  └─ environment-check   download and load the image in a fresh job
                         check: same image ID, same version, same commit as the build reported
                         then, for each of the four standard legs: start → prove → save logs → stop
```

1. **resolve** looks up the newest commit of the branch you gave (default `v3.0`) in
   `sysown/proxysql`. If you give a full 40-character commit instead, it uses that commit as is. From
   this point only the commit is passed on, so the tested code cannot change in the middle of a run.
2. **build** checks out that commit and runs `PROXYSQL40=1 WITHGCOV=1 make ubuntu24-dbg`: ProxySQL 4.0,
   debug build, with code-coverage instrumentation, the same build the legacy pipeline uses. This is
   the slow part of a run; the job is stopped after 180 minutes. The `.deb` package it produces is
   installed into a Docker image based on the pinned `ubuntu:24.04` image. The job then checks that
   `proxysql --version` inside the image is `4.0.x` and contains the first 7 characters of the commit,
   and uploads the image and the build log.
3. **environment-check** runs on a different machine. It downloads the image, loads it, and fails if
   its image ID, version or commit differ from what the build reported. It then brings up each of the
   four standard legs (see [How a leg works](#how-a-leg-works)), proves it, saves its logs and removes
   it. The job fails if any leg is not ready. Its summary on the run page shows the image and one row
   per leg. In stage 3 this job is replaced by the test-suite jobs, which use the same scripts around
   their tests.

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

**ProxySQL settings.** ProxySQL runs with its default settings. Per leg, only what the setup needs is
changed, through the admin interface:

- one user in `pgsql_users` (with `fast_forward=0`, so ProxySQL handles the protocol itself);
- one server in `pgsql_servers`: `pg:5432` in hostgroup 0, with `use_ssl` as above;
- `pgsql-server_version` set to the real PostgreSQL version, because ProxySQL's default (`16.1`) would
  mislead drivers about what the server supports.

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
3. Click **Run workflow**, keep or change `proxysql_ref`, and click the green **Run workflow** button.

`proxysql_ref` accepts a `sysown/proxysql` branch name (for example `v3.0`) or a full, lowercase
40-character commit. Short commits and tags are not accepted.

From the command line: `gh workflow run pgsql-3p.yml -f proxysql_ref=v3.0`.

To run a version of the workflow from another branch of this repository (for example, to try a change
before merging), choose that branch in the **Use workflow from** list, or add `--ref <branch>` to the
`gh` command. This works once `pgsql-3p.yml` exists on `main`.

Several runs can go at the same time, for example to test several ProxySQL commits.

## Results and downloads

Open a run from the **Actions** tab. The page shows each job with its steps and logs, the summary of
`image-check` (ProxySQL version and image ID), and an **Artifacts** section at the bottom with the
files the run produced:

| Artifact | Contents | Kept for |
|---|---|---|
| `pgsql-3p-proxysql-image-<commit>` | `proxysql-image.tar.zst`, the ProxySQL runtime image | 3 days |
| `pgsql-3p-build-log-<commit>-attempt<n>` | `build.log`, the full build output (one per attempt, so a re-run keeps the earlier log) | 7 days |
| `pgsql-3p-environment-<commit>-attempt<n>` | One folder per leg with the files below | 7 days |

Each leg folder (`<leg>/artifacts/`) holds:

| File | Contents |
|---|---|
| `leg.json` | Leg name, TLS settings, status and reason, start and end time, images, PostgreSQL version, backend protocol, ProxySQL config fingerprint |
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

## When a run fails

| Message | Meaning |
|---|---|
| `invalid ref '...'` or `branch '...' not found` | `proxysql_ref` is not an existing branch or a full 40-character commit |
| The build step fails | ProxySQL did not compile; download the build log artifact |
| `not a v4.0 build: '...'` | The build did not produce ProxySQL 4.0 (for example, a changed Makefile flag) |
| `version '...' is not commit ...` | The binary was not built from the requested commit |
| `expected exactly one proxysql_*.deb in ...` | The build produced no package, or more than one |
| `image ... has ID ..., expected ...` | A job loaded a different image than the build produced (wrong or stale artifact); re-run the whole workflow |
| `legs not ready: ...` | At least one leg's setup failed; the summary table and that leg's `leg.json` give the step and the reason |
| `<leg>: infra_failure: start postgresql: ...` | PostgreSQL did not start or did not become healthy within 120 seconds; see `postgresql.log` |
| `<leg>: infra_failure: start proxysql: ...` | The ProxySQL container did not start, or its admin port was not reachable within 60 seconds; see `proxysql.log` |
| `... use_native_backend_protocol is '...', expected 'true'` | The build does not use the native backend protocol by default (for example, a changed build flag) |
| `... pg_stat_ssl.ssl is 't', expected 'f'` (or the reverse) | TLS on one side is not what the leg requires |
| `private key in ...` / `secret value in ...` | The upload check found a key or a password in a leg's files; nothing was uploaded |

## Testing the scripts locally

```bash
bash pgsql/lib/tests/test-resolve-ref.sh   # needs network access to github.com
bash pgsql/lib/tests/test-image.sh         # needs docker, dpkg-deb, zstd and network access; a few minutes
```

`test-image.sh` uses small fake ProxySQL packages instead of the real build, so it checks the scripts'
behaviour (version and commit checks, package selection, image size, image ID checks), not ProxySQL.

```bash
bash pgsql/lib/tests/test-certs.sh   # needs openssl
bash pgsql/lib/tests/test-guard.sh   # needs openssl
PROXYSQL_IMAGE=pgsql-3p-proxysql:<commit> bash pgsql/lib/tests/test-legs.sh   # docker, jq; about 5 minutes
```

`test-legs.sh` brings up all six legs with a real ProxySQL image, checks each one, and also checks
that a wrong TLS expectation fails, that a missing image is reported as an `infra_failure`, and that
nothing is left behind. To get the image of a run (kept for 3 days):

```bash
gh run download <run-id> -R ProxySQL/proxysql_3p_testing_public -n pgsql-3p-proxysql-image-<commit>
zstd -dc proxysql-image.tar.zst | docker load
```

To bring up one leg by hand and look around:

```bash
bash pgsql/lib/certs.sh /tmp/pgsql3p-certs
CERT_DIR=/tmp/pgsql3p-certs PROXYSQL_IMAGE=pgsql-3p-proxysql:<commit> bash pgsql/lib/leg-up.sh proxy-tls /tmp/leg
docker compose --env-file /tmp/leg/compose.env exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin
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
3. The first test suite, pgJDBC, run directly against PostgreSQL and through ProxySQL.
4. Per-suite reports: passed, failed, skipped and errored tests, and the list of tests that pass on
   PostgreSQL but fail through ProxySQL.
5. Comparison with earlier runs (new failures, fixed tests, flaky tests).
6. Complete documentation, followed by more test suites, one at a time.
