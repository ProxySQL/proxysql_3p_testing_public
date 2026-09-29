# ProxySQL 3rd-party testing (CI runner)

This repository runs the ProxySQL **3rd-party test suites** (connectors and frameworks such as aiomysql,
SQLAlchemy, Django, Laravel, PHP PDO, MySQL Connector/J, MariaDB Connector/C, pgJDBC, PostgreSQL regression)
against ProxySQL builds, on GitHub Actions.

It holds **only thin wrapper workflows**. The logic lives elsewhere:

| What | Where |
|---|---|
| Reusable workflows (`ci-3p-<suite>.yml`) | [`sysown/proxysql`](https://github.com/sysown/proxysql), branch `GH-Actions`, `.github/workflows/` |
| ProxySQL build tested | `sysown/proxysql` CI-builds artifact `ci-builds-handoff-<sha>-ubuntu24-tap-genai-gcov-full` (v4.0 tier, `PROXYSQL40=1 WITHGCOV=1`, ubuntu24) |
| Test harness | `ProxySQL/proxysql_3p_testing` (private) |

Why a separate repository: a reusable workflow runs in the context of the repository that calls it (runners,
concurrency, token). Running the ~90 3rd-party matrix jobs per commit here keeps them from competing with
the regular ProxySQL CI for hosted runners.

## Workflows

- `CI-3p-<suite>.yml` — one wrapper per suite, started with `workflow_dispatch` (inputs: ProxySQL `sha`,
  `branch`, CI-builds `build_run_id`). The matrix comes from the repository variables
  `MATRIX_3P_<SUITE>_INFRADB_<MYSQL|MARIADB|PGSQL>` / `MATRIX_3P_<SUITE>_CONNECTOR_<...>`.
- `CI-3p-poller.yml` — scheduled: finds new successful CI-builds runs of the tracked `sysown/proxysql`
  branches and dispatches every **enabled** `CI-3p-*` wrapper for that commit once. Enable or disable a
  suite by enabling or disabling its workflow.

## Secrets

- `PROXYSQL_3P_TESTING_DEPLOY_KEY` — read-only deploy key of `ProxySQL/proxysql_3p_testing`.
- `PROXYSQL_ARTIFACTS_TOKEN` — optional, only if the workflow token cannot download `sysown/proxysql` artifacts.

Workflows here are never triggered by pull requests.

Tracking: sysown/proxysql#6244, ProxySQL/proxysql_3p_testing#24.
