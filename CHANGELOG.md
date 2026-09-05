# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-09-05

### Added

- **Restores the newest dump into a throwaway database and checks the result.**
  PostgreSQL and MySQL or MariaDB, from the same image the live service runs,
  on a quarterly systemd timer. The live database is never touched.
- **Roles are created before the restore.** `pg_dump` writes `OWNER TO` and
  never `CREATE ROLE`, so a dump restored into a fresh cluster errors once per
  owned object and silently reassigns ownership. The drill extracts the roles
  the dump refers to and creates them first.
- **A table count, because an empty dump is valid.** A gzip of a SQL script
  that creates nothing passes every integrity check there is.
  `DRILL_MIN_TABLES` is what catches it.
- **Two stamps rather than one.** `last-run` is written before any verdict and
  answers "is the drill still running"; `last-ok` only after a clean result and
  answers "is the newest backup restorable". A watcher with one of them cannot
  tell a drill that keeps failing from one that stopped.
- **Ten end-to-end scenarios** against real PostgreSQL and MariaDB containers,
  including the three that must fail: a truncated archive, an empty but valid
  dump, and a `.partial` file newer than every real backup.

### Fixed

- **Readiness required a liveness probe, which both images answer too early.**
  PostgreSQL and MariaDB each start a temporary server to run their own
  initialisation, and `pg_isready` and `mariadb-admin ping` answer it. The
  drill went ahead before the credentials existed and failed with access
  denied. Readiness now requires an authenticated query to return a row. Found
  by the MariaDB scenarios in the test suite, on the first run that exercised
  that path.

[Unreleased]: https://github.com/heyvaldemar/restore-drill/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/restore-drill/releases/tag/v1.0.0
