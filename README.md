# Restore drill

[![Restore Drill Tests](https://github.com/heyvaldemar/restore-drill/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/restore-drill/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A backup nobody has restored is a hypothesis.

This restores your newest database dump into a throwaway container built from the same image your live database runs, counts what came back, and requires zero errors. It never touches the live database. Run it quarterly from a systemd timer next to any Docker Compose stack that writes dumps.

## What it catches that a checksum cannot

Freshness says the file was written. `gzip -t` says it was not corrupted on disk. Neither says it will load. Three failures pass both and fail here:

**A dump written by a client newer than its own server.** A backup sidecar pinned one major version ahead of the database it dumps writes statements that database cannot parse. Found in production between a `postgres:18` sidecar and a `postgres:14` database: `SET transaction_timeout`, in every dump, for months. Everything was green. The drill uses the same image as the live service, so a mismatch fails on a Sunday morning instead of during a recovery.

**Roles that exist in the cluster and not in the dump.** `pg_dump` writes `OWNER TO` and never `CREATE ROLE`, because roles are cluster-level objects. Restore into a fresh cluster and you get one error per owned object — 245 of them in the case that prompted this — and the objects end up owned by whoever ran the restore. The drill extracts the roles the dump refers to and creates them first, which is what a real recovery has to do anyway.

**A dump that loads perfectly and contains nothing.** A valid gzip of a valid SQL script that creates no tables passes every integrity check ever written. Point `DRILL_LIVE_CONTAINER` at the running database and the drill requires back every table the live one has, naming what did not come; `DRILL_MIN_TABLES` is the fallback when you cannot, and it only catches the completely empty case.

## Install

```bash
sudo install -m 755 restore-drill.sh /usr/local/sbin/restore-drill.sh
sudo install -m 644 restore-drill@.service restore-drill@.timer /etc/systemd/system/
sudo mkdir -p /etc/restore-drill
sudo cp restore-drill.env.example /etc/restore-drill/nextcloud.env
sudo chmod 600 /etc/restore-drill/nextcloud.env
sudo $EDITOR /etc/restore-drill/nextcloud.env
sudo systemctl enable --now restore-drill@nextcloud.timer
```

One env file per stack; the unit is templated, so `restore-drill@mattermost` and `restore-drill@nextcloud` run independently off their own configuration.

Run it by hand first, and watch it:

```bash
sudo systemctl start restore-drill@nextcloud.service
journalctl -u restore-drill@nextcloud -n 40 --no-pager
```

## Two stamps, and why

`/var/lib/restore-drill/last-run` is written every time the drill executes, before any verdict. `last-ok` is written only after a clean result.

They answer different questions. The first is "is the drill still running", the second is "is the newest backup restorable". A watcher that thresholds on the second alone cannot tell a drill that keeps failing from one that stopped a month ago, and those need different responses. Point your dead man's switch at `last-run` and your alerting at `last-ok`.

Success is a change of state, never the presence of a file. Both stamps are written by this run or not at all — a marker left by a previous run must never be able to report today as healthy.

## Configuration

Every knob lives in the env file; `restore-drill.env.example` documents each one inline. The two worth thinking about are `DRILL_IMAGE`, which must match the live database's image rather than being the newest available, and `DRILL_LIVE_CONTAINER`, which makes the live schema the reference instead of a number you would have to keep revising. Without it the drill falls back to `DRILL_MIN_TABLES`, a floor that passes for a dump which restored a fifth of the schema and goes on passing as the application grows away from it.

## What it does not do

It does not verify the application works against the restored data — only that the dump loads and produces a schema. It does not drill file backups, only database dumps. It does not read MongoDB archives; `mongodump --archive` is its own format and needs its own handling.

It reads dumps and writes only to throwaway containers and its own state directory. It never connects to the live database.

## Testing

`tests/e2e-restore-drill.sh` runs ten scenarios against real PostgreSQL and MariaDB containers: a genuine dump restores, a role the dump references is created for it, both stamps behave, a truncated archive fails, an empty-but-valid dump is caught by the table count, the run stamp still moves when the drill fails, and a newer `.partial` or `.failed` file is never mistaken for a backup.

Writing that suite found a real defect in this script. The readiness check used a liveness probe, and both database images answer one from the temporary server they start to run their own initialisation — so "ready" arrived before the credentials existed and the restore failed with access denied. Readiness now requires an authenticated query to return a row, which is the only form of the check that means what it says.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
