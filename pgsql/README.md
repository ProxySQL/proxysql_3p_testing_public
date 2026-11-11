# PostgreSQL 3rd-party tests

This folder holds a pipeline that will run the original test suites of PostgreSQL drivers (pgJDBC,
psycopg, pgx and others) through ProxySQL and directly against PostgreSQL, and compare the results.
It runs on GitHub Actions in this repository and does not depend on any private scripts.

It is separate from the existing MySQL/legacy pipeline (`CI-3p.yml`, `3p-build.yml`, `3p-suite.yml`),
which is not changed. The PostgreSQL suites that the legacy pipeline runs keep running until this
pipeline has a replacement for each of them.

**Status: stage 1.** The pipeline builds ProxySQL and proves that every later job gets exactly that
build. No test suites run yet; they are added in later stages (see [What comes next](#what-comes-next)).

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
  └─ image-check  download and load the image in a fresh job
                  check: same image ID, same version, same commit as the build reported
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
3. **image-check** runs on a different machine. It downloads the image, loads it, and fails if its
   image ID, version or commit differ from what the build reported. Its summary on the run page shows
   the version and image ID. In stage 3 this job is replaced by the test-suite jobs, which do the same
   check before running their tests.

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

## Testing the scripts locally

```bash
bash pgsql/lib/tests/test-resolve-ref.sh   # needs network access to github.com
bash pgsql/lib/tests/test-image.sh         # needs docker, dpkg-deb, zstd and network access; a few minutes
```

`test-image.sh` uses small fake ProxySQL packages instead of the real build, so it checks the scripts'
behaviour (version and commit checks, package selection, image size, image ID checks), not ProxySQL.

## Updating the pinned images

`pgsql/versions.env` pins each image by digest, so every run uses exactly the same image. To move to a
newer image, look up its digest and replace the whole value, for example:

```bash
docker buildx imagetools inspect postgres:18.6-trixie | grep -m1 '^Digest:'
```

Write the value as `<image>:<tag>@<digest>` and update the date comment in the file.

## What comes next

Each stage is added on top of this one, and this file is extended with it:

2. The test environment: PostgreSQL 18.6 and ProxySQL started in Docker, with and without TLS.
3. The first test suite, pgJDBC, run directly against PostgreSQL and through ProxySQL.
4. Per-suite reports: passed, failed, skipped and errored tests, and the list of tests that pass on
   PostgreSQL but fail through ProxySQL.
5. Comparison with earlier runs (new failures, fixed tests, flaky tests).
6. Complete documentation, followed by more test suites, one at a time.
