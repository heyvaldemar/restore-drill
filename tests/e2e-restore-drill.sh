#!/bin/bash
# Does the drill actually tell a good backup from a bad one?
#
# Six scenarios against real database containers and real dumps. Each one
# exists because a check that only ever sees healthy input is not known to
# work — the whole point of a restore drill is the day the input is not
# healthy, and that is the case that must be exercised deliberately.
#
#   ./tests/e2e-restore-drill.sh
#
# Needs docker. Everything it creates is named for this run and removed on
# exit, including on failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRILL="$ROOT/restore-drill.sh"
PG_IMAGE="${PG_IMAGE:-postgres:16-alpine}"
WORK="$(mktemp -d)"
RUN="drilltest-$$"
PASSED=0; FAILED=0

cleanup() {
  docker rm -f "$RUN-source" "$RUN-msource" >/dev/null 2>&1
  docker ps -aq --filter "name=restore-drill-" | xargs -r docker rm -f >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

# shellcheck disable=SC2120  # takes no arguments; the env is the interface
drill() {   # runs the drill over $WORK/backups, prints everything, returns its code
  DRILL_ENGINE=postgres DRILL_IMAGE="$PG_IMAGE" \
  DRILL_BACKUPS_PATH="$WORK/backups" DRILL_DB_NAME=appdb DRILL_DB_USER=appuser \
  DRILL_DB_PASSWORD=drilltestpassword DRILL_STATE_DIR="$WORK/state" \
  DRILL_TIMEOUT=120 env "$@" bash "$DRILL" 2>&1
  # `env`, not a bare "$@": a word that comes out of an expansion is an
  # argument, not an assignment, so `VAR=x` handed in this way reached the
  # shell as a command to run and every case using it failed on "command not
  # found" while looking like the drill had rejected the input.
}

echo "=== restore drill: does it tell a good backup from a bad one? ==="
mkdir -p "$WORK/backups" "$WORK/state"

# ---------------------------------------------------------------- a real dump
echo
echo "building a source database and dumping it"
docker rm -f "$RUN-source" >/dev/null 2>&1
docker run -d --name "$RUN-source" -e POSTGRES_DB=appdb -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=drilltestpassword "$PG_IMAGE" >/dev/null || { echo "cannot start postgres"; exit 1; }
# An AUTHENTICATED query, not pg_isready. The image starts a temporary server
# to run its own initialisation and a liveness probe answers it, so "ready"
# arrives before the credentials exist. This bug was in the drill itself until
# the MariaDB scenarios found it; it was still here, in the harness.
ready=false
for _ in $(seq 1 90); do
  if docker exec "$RUN-source" psql -tAq -U appuser -d appdb -c 'select 1' 2>/dev/null | grep -q '^1$'; then ready=true; break; fi
  sleep 2
done
[ "$ready" = true ] || { echo "the source postgres never accepted an authenticated query"; docker logs "$RUN-source" 2>&1 | tail -10; exit 1; }
docker exec "$RUN-source" psql -q -U appuser -d appdb -c "
  create role reporting;
  create table invoices(id serial primary key, total numeric);
  create table customers(id serial primary key, name text);
  insert into invoices(total) select generate_series(1,50);
  alter table invoices owner to reporting;" \
  || { echo "cannot seed the source database"; exit 1; }
docker exec "$RUN-source" pg_dump -U appuser -d appdb | gzip > "$WORK/backups/app-2026-09-05_00-00.gz"
# A dump this small is an empty one, and an empty fixture makes every scenario
# below meaningless while looking like a real failure of the thing under test.
[ "$(wc -c < "$WORK/backups/app-2026-09-05_00-00.gz")" -gt 300 ] \
  || { echo "the source dump is empty - the fixture failed, not the drill"; exit 1; }
echo "  dump: $(wc -c < "$WORK/backups/app-2026-09-05_00-00.gz" | tr -d ' ') bytes"

# 1. the good case
out="$(drill)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "DRILL OK"; then
  pass "a real dump restores and is reported OK"
else
  fail "a real dump was rejected"; printf '%s\n' "$out" | sed 's/^/        /' | tail -8
fi

# 2. the role the dump hands objects to must be created for it
#    Without this the restore emits one error per owned object and the drill
#    would report failure on a backup that is actually fine.
if printf '%s' "$out" | grep -q "pre-created roles from the dump"; then
  pass "roles referenced by the dump are created before the restore"
else
  fail "the dump owns a table by 'reporting' and no role was pre-created"
fi

# 2b. THE LIVE DATABASE AS THE REFERENCE, and the floor it replaces.
#     DRILL_MIN_TABLES is a number somebody wrote once: it passes for a dump
#     that restored a fifth of the schema and keeps passing as the application
#     grows away from it. Pointed at the running database, the drill asks what
#     it has and requires all of it back.
out="$(drill DRILL_LIVE_CONTAINER="$RUN-source")"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "every one of 2 live tables present"; then
  pass "a complete dump matches the live schema table for table"
else
  fail "a complete dump was not recognised as complete"; printf '%s\n' "$out" | sed 's/^/        /' | tail -6
fi

#     The case that matters: the live database grows a table the dump predates.
#     The floor cannot see this at all — two tables still clears a floor of one.
docker exec "$RUN-source" psql -q -U appuser -d appdb \
  -c "create table payments(id serial primary key, amount numeric);" >/dev/null 2>&1
out="$(drill DRILL_LIVE_CONTAINER="$RUN-source")"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "did not come back"; then
  pass "a table the live database has and the dump does not is a failure"
else
  fail "a dump missing a live table was accepted"; printf '%s\n' "$out" | sed 's/^/        /' | tail -6
fi
if printf '%s' "$out" | grep -q "payments"; then
  pass "and it names the table that did not come back"
else
  fail "it failed without saying which table was missing"
fi
#     The same input under the old floor passes, which is the whole argument.
out="$(drill DRILL_MIN_TABLES=1)"; rc=$?
if [ $rc -eq 0 ]; then
  pass "and the hand-written floor accepts that same dump, as it always did"
else
  fail "the floor rejected a dump it should have passed"
fi
docker exec "$RUN-source" psql -q -U appuser -d appdb -c "drop table payments;" >/dev/null 2>&1

#     A live database that cannot be read is not a clean drill.
out="$(drill DRILL_LIVE_CONTAINER="$RUN-no-such-container")"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "comparison did not happen"; then
  pass "an unreadable live database fails rather than passing empty"
else
  fail "an unreadable live database was read as nothing missing"
fi

# 3. the OK stamp is written only on success, and the RUN stamp always
if [ -f "$WORK/state/last-run" ] && [ -f "$WORK/state/last-ok" ]; then pass "both stamps written after a clean drill"; else fail "stamps missing after a clean drill"; fi

# 4. a truncated archive
cp "$WORK/backups/app-2026-09-05_00-00.gz" "$WORK/good.gz"
head -c 400 "$WORK/good.gz" > "$WORK/backups/app-2026-09-05_01-00.gz"
rm -f "$WORK/state/last-ok"
out="$(drill)"; rc=$?
if [ $rc -ne 0 ] && [ ! -f "$WORK/state/last-ok" ]; then
  pass "a truncated archive fails the drill and writes no OK stamp"
else
  fail "a truncated archive passed"; printf '%s\n' "$out" | sed 's/^/        /' | tail -6
fi

# 5. a dump that is readable, loads without error, and contains nothing.
#    This is the one a checksum check can never catch: the file is a perfectly
#    valid gzip of a perfectly valid SQL script that creates no tables.
printf 'SELECT 1;\n' | gzip > "$WORK/backups/app-2026-09-05_02-00.gz"
rm -f "$WORK/state/last-ok"
out="$(drill)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "restored only"; then
  pass "an empty but valid dump is caught by the table count"
else
  fail "an empty dump passed the drill"; printf '%s\n' "$out" | sed 's/^/        /' | tail -6
fi

# 6. the RUN stamp still moves when the drill fails: a watcher must be able to
#    tell a drill that is failing from one that has stopped running.
before="$(cat "$WORK/state/last-run")"
sleep 1
drill >/dev/null 2>&1
after="$(cat "$WORK/state/last-run")"
if [ "$after" != "$before" ]; then pass "the run stamp moves even on a failing drill"; else fail "the run stamp did not move, so a stopped drill looks like a failing one"; fi

# 7. .partial and .failed files are never selected
rm -f "$WORK/backups"/*.gz
cp "$WORK/good.gz" "$WORK/backups/app-2026-09-05_03-00.gz"
sleep 1
cp "$WORK/good.gz" "$WORK/backups/app-2026-09-05_04-00.gz.partial"
cp "$WORK/good.gz" "$WORK/backups/app-2026-09-05_05-00.gz.failed"
out="$(drill)"
if printf '%s' "$out" | grep -q "app-2026-09-05_03-00.gz"; then
  pass "a newer .partial or .failed file is not mistaken for a backup"
else
  fail "the drill picked a partial or failed file"; printf '%s\n' "$out" | sed 's/^/        /' | head -4
fi

# ---------------------------------------------------------- the MariaDB path
# Supported, therefore exercised. A branch that is documented and never run is
# a branch that works until the first person needs it.
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
echo
echo "the same three questions against $MARIADB_IMAGE"
mkdir -p "$WORK/mbackups" "$WORK/mstate"
mdrill() {
  DRILL_ENGINE=mysql DRILL_IMAGE="$MARIADB_IMAGE" \
  DRILL_BACKUPS_PATH="$WORK/mbackups" DRILL_DB_NAME=appdb DRILL_DB_USER=root \
  DRILL_DB_PASSWORD=drilltestpassword DRILL_STATE_DIR="$WORK/mstate" \
  DRILL_TIMEOUT=180 bash "$DRILL" 2>&1
}
docker rm -f "$RUN-msource" >/dev/null 2>&1
docker run -d --name "$RUN-msource" -e MARIADB_DATABASE=appdb \
  -e MARIADB_ROOT_PASSWORD=drilltestpassword "$MARIADB_IMAGE" >/dev/null
mready=false
for _ in $(seq 1 120); do
  if docker exec "$RUN-msource" mariadb -uroot -pdrilltestpassword -NBe 'select 1' 2>/dev/null | grep -q '^1$'; then mready=true; break; fi
  sleep 2
done
[ "$mready" = true ] || { echo "the source mariadb never accepted an authenticated query"; docker logs "$RUN-msource" 2>&1 | tail -10; exit 1; }
docker exec "$RUN-msource" mariadb -uroot -pdrilltestpassword appdb -e "
  create table invoices(id int primary key auto_increment, total decimal(10,2));
  create table customers(id int primary key auto_increment, name varchar(64));
  insert into invoices(total) values (1),(2),(3);" \
  || { echo "cannot seed the source mariadb"; exit 1; }
docker exec "$RUN-msource" mariadb-dump -uroot -pdrilltestpassword appdb | gzip > "$WORK/mbackups/app-2026-09-05_00-00.gz"
[ "$(wc -c < "$WORK/mbackups/app-2026-09-05_00-00.gz")" -gt 300 ] \
  || { echo "the source mariadb dump is empty - the fixture failed, not the drill"; exit 1; }

out="$(mdrill)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "DRILL OK"; then
  pass "a real MariaDB dump restores and is reported OK"
else
  fail "a real MariaDB dump was rejected"; printf '%s\n' "$out" | sed 's/^/        /' | tail -8
fi

printf 'SELECT 1;\n' | gzip > "$WORK/mbackups/app-2026-09-05_01-00.gz"
rm -f "$WORK/mstate/last-ok"
out="$(mdrill)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q "restored only"; then
  pass "an empty but valid MariaDB dump is caught by the table count"
else
  fail "an empty MariaDB dump passed"; printf '%s\n' "$out" | sed 's/^/        /' | tail -6
fi

head -c 400 "$WORK/mbackups/app-2026-09-05_00-00.gz" > "$WORK/mbackups/app-2026-09-05_02-00.gz"
rm -f "$WORK/mstate/last-ok"
out="$(mdrill)"; rc=$?
if [ $rc -ne 0 ]; then pass "a truncated MariaDB archive fails the drill"; else fail "a truncated MariaDB archive passed"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
