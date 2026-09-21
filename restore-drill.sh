#!/bin/bash
# restore-drill.sh — restore the newest dump into a throwaway database and
# check the result. Never touches the live one.
#
# WHY THIS EXISTS. Everything else in a backup setup proves the file EXISTS and
# is INTACT: it is fresh, gzip -t passes, the checksums match. None of that
# proves it RESTORES. A dump truncated at write time, taken from a database
# mid-migration, or written by a client newer than the server it must be loaded
# into, passes every one of those checks and fails on the day you need it.
#
# A backup nobody has restored is a hypothesis.
#
# The first run of this drill against a live home server found two defects that
# every freshness and checksum check had been green through for months. Both
# are handled below and both are worth knowing about:
#
#   1. pg_dump writes `OWNER TO`, and never `CREATE ROLE`. Roles live at the
#      cluster level, not in the database, so a dump restored into a fresh
#      cluster produces one `role "..." does not exist` error per owned object
#      - 245 of them, in that case - and the objects land owned by whoever ran
#      the restore. The drill extracts the roles the dump refers to and creates
#      them first, because that is what a real restore has to do.
#
#   2. A dump is only loadable by a server at least as new as the client that
#      wrote it. A backup sidecar pinned to postgres:18 dumping a live
#      postgres:14 writes `SET transaction_timeout`, which 14 rejects. The
#      backup looked perfect and could not be restored into its own database.
#      The drill uses the SAME image as the live service, so a mismatch fails
#      here rather than in an outage.
#
# EXIT CODES: 0 the dump restored and the schema looks sane, 1 it did not.
# Everything it says goes to stdout with a timestamp; the caller decides what
# to do with a failure. Nothing here writes to the live database.

set -uo pipefail

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "DRILL FAILED: $*"; exit 1; }

: "${DRILL_ENGINE:?set DRILL_ENGINE to postgres or mysql}"
: "${DRILL_IMAGE:?set DRILL_IMAGE to the SAME image the live database runs}"
: "${DRILL_BACKUPS_PATH:?set DRILL_BACKUPS_PATH to the directory holding the dumps}"
: "${DRILL_DB_NAME:?set DRILL_DB_NAME}"
: "${DRILL_DB_USER:?set DRILL_DB_USER}"
: "${DRILL_DB_PASSWORD:?set DRILL_DB_PASSWORD}"
DRILL_PATTERN="${DRILL_PATTERN:-*.gz}"
DRILL_MIN_TABLES="${DRILL_MIN_TABLES:-1}"
# THE LIVE DATABASE IS THE ONLY REFERENCE THAT DOES NOT GO STALE.
#
# A floor written by hand is a number nobody revisits: it passes for a dump
# that restored a fifth of the schema, and it keeps passing as the application
# grows away from it. Name the running container and the drill asks it what it
# has, then requires the restored copy to have all of it and says what did not
# come back. Unset, the floor below is still applied — and it is the weaker
# check, which this says out loud rather than leaving to be assumed.
DRILL_LIVE_CONTAINER="${DRILL_LIVE_CONTAINER:-}"
DRILL_TIMEOUT="${DRILL_TIMEOUT:-300}"
STATE_DIR="${DRILL_STATE_DIR:-/var/lib/restore-drill}"

mkdir -p "$STATE_DIR"

# The RUN stamp is written unconditionally and answers "did this drill
# execute". The OK stamp is written only after a clean result and answers "is
# the newest backup restorable". Two questions, two files: a watcher that
# thresholds on the second alone cannot tell a drill that stopped running from
# one that keeps failing, and both need saying out loud.
date +%s > "$STATE_DIR/last-run"

# --- pick the newest dump ------------------------------------------------
# -print0 and a null-delimited sort, because a filename is allowed to contain
# anything except NUL, and because `find | head -1` kills find with SIGPIPE
# under `set -o pipefail`, which reads as "no backups found".
newest=""
while IFS= read -r -d '' f; do
  if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
done < <(find "$DRILL_BACKUPS_PATH" -maxdepth 1 -type f -name "$DRILL_PATTERN" \
           ! -name '*.partial' ! -name '*.failed' -print0 2>/dev/null)

[ -n "$newest" ] || die "no backup matching '$DRILL_PATTERN' in $DRILL_BACKUPS_PATH"
log "newest backup: $newest ($(wc -c < "$newest" | tr -d ' ') bytes)"

# Readable before anything else is started: a truncated archive should fail
# here, in one second, not after a database has been brought up for it.
gzip -t "$newest" 2>/dev/null || die "$newest is not a readable gzip archive"

CONTAINER="restore-drill-$$-$(date +%s)"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

case "$DRILL_ENGINE" in
  postgres)
    docker run -d --name "$CONTAINER" \
      -e POSTGRES_DB="$DRILL_DB_NAME" -e POSTGRES_USER="$DRILL_DB_USER" \
      -e POSTGRES_PASSWORD="$DRILL_DB_PASSWORD" "$DRILL_IMAGE" >/dev/null \
      || die "could not start a throwaway $DRILL_IMAGE"
    # An AUTHENTICATED query, not pg_isready. Both database images start a
    # temporary server to run their initialisation, and a liveness probe
    # answers it happily — so "ready" arrives before the credentials the
    # restore needs exist. Requiring a real answer to a real query is the only
    # form of this check that means what it says.
    ready="psql -tAq -U $DRILL_DB_USER -d $DRILL_DB_NAME -c 'select 1' | grep -q '^1$'"
    ;;
  mysql|mariadb)
    docker run -d --name "$CONTAINER" \
      -e MARIADB_DATABASE="$DRILL_DB_NAME" -e MYSQL_DATABASE="$DRILL_DB_NAME" \
      -e MARIADB_ROOT_PASSWORD="$DRILL_DB_PASSWORD" -e MYSQL_ROOT_PASSWORD="$DRILL_DB_PASSWORD" \
      "$DRILL_IMAGE" >/dev/null || die "could not start a throwaway $DRILL_IMAGE"
    ready="mariadb -uroot -p$DRILL_DB_PASSWORD -NBe 'select 1' | grep -q '^1$'"
    ;;
  *) die "DRILL_ENGINE must be postgres or mysql, not '$DRILL_ENGINE'" ;;
esac

log "waiting up to ${DRILL_TIMEOUT}s for the throwaway database"
deadline=$(( $(date +%s) + DRILL_TIMEOUT ))
until docker exec "$CONTAINER" sh -c "$ready" >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] || die "the throwaway database never became ready"
  sleep 2
done

# --- restore -------------------------------------------------------------
errors=0
if [ "$DRILL_ENGINE" = "postgres" ]; then
  # Create the roles the dump will hand objects to. See the note at the top:
  # pg_dump never emits CREATE ROLE, so without this every owned object errors
  # and the restore "succeeds" with the wrong owner everywhere.
  roles="$(gunzip -c "$newest" | grep -oE '^(ALTER .* OWNER TO|GRANT .* TO) [A-Za-z0-9_]+' \
           | awk '{print $NF}' | sort -u | grep -vE '^(PUBLIC|CURRENT_USER|SESSION_USER)$' || true)"
  for r in $roles; do
    [ "$r" = "$DRILL_DB_USER" ] && continue
    docker exec "$CONTAINER" psql -U "$DRILL_DB_USER" -d "$DRILL_DB_NAME" \
      -c "DO \$\$ BEGIN CREATE ROLE \"$r\"; EXCEPTION WHEN duplicate_object THEN NULL; END \$\$;" \
      >/dev/null 2>&1 || log "note: could not pre-create role $r"
  done
  [ -n "$roles" ] && log "pre-created roles from the dump: $(echo "$roles" | tr '\n' ' ')"

  out="$(gunzip -c "$newest" | docker exec -i "$CONTAINER" \
        psql -v ON_ERROR_STOP=0 -U "$DRILL_DB_USER" -d "$DRILL_DB_NAME" 2>&1)"
  errors="$(printf '%s' "$out" | grep -c '^ERROR:' || true)"
  tables="$(docker exec "$CONTAINER" psql -tAq -U "$DRILL_DB_USER" -d "$DRILL_DB_NAME" \
            -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');" 2>/dev/null || echo 0)"
else
  out="$(gunzip -c "$newest" | docker exec -i "$CONTAINER" \
        sh -c "mariadb -uroot -p$DRILL_DB_PASSWORD $DRILL_DB_NAME" 2>&1)"
  errors="$(printf '%s' "$out" | grep -ci '^ERROR' || true)"
  tables="$(docker exec "$CONTAINER" sh -c \
            "mariadb -uroot -p$DRILL_DB_PASSWORD -NBe \"select count(*) from information_schema.tables where table_schema='$DRILL_DB_NAME';\"" 2>/dev/null || echo 0)"
fi

printf '%s' "$out" | grep -iE '^(ERROR|FATAL)' | head -5 | while IFS= read -r l; do log "  $l"; done

[ "${errors:-1}" -eq 0 ] || die "$errors errors while restoring $newest"

# table_list <container>: one table name per line, sorted, empty on any failure.
table_list() {
  if [ "$DRILL_ENGINE" = postgres ]; then
    docker exec "$1" psql -tAq -U "$DRILL_DB_USER" -d "$DRILL_DB_NAME" \
      -c "select table_name from information_schema.tables where table_schema not in ('pg_catalog','information_schema') order by 1;" 2>/dev/null
  else
    docker exec "$1" sh -c \
      "mariadb -uroot -p$DRILL_DB_PASSWORD -NBe \"select table_name from information_schema.tables where table_schema='$DRILL_DB_NAME' order by 1;\"" 2>/dev/null
  fi
}

if [ -n "$DRILL_LIVE_CONTAINER" ]; then
  live="$(table_list "$DRILL_LIVE_CONTAINER")"
  # An unreachable live database answers the same as one with no tables, and
  # reading that as "nothing is missing" would turn this into a check that
  # cannot fail — the exact shape this whole tool exists to refuse.
  [ -n "$live" ] \
    || die "could not read the table list from $DRILL_LIVE_CONTAINER — the comparison did not happen, which is not the same as a clean drill"
  restored="$(table_list "$CONTAINER")"
  missing="$(comm -23 <(printf '%s\n' "$live" | sort -u) <(printf '%s\n' "$restored" | sort -u))"
  if [ -n "$missing" ]; then
    count="$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
    die "$count table(s) the live database has did not come back: $(printf '%s' "$missing" | tr '\n' ' ' | cut -c1-300)"
  fi
  log "DRILL OK: $newest restored into a throwaway $DRILL_IMAGE, every one of $(printf '%s\n' "$live" | wc -l | tr -d ' ') live tables present, 0 errors"
else
  [ "${tables:-0}" -ge "$DRILL_MIN_TABLES" ] \
    || die "restored only ${tables:-0} tables, expected at least $DRILL_MIN_TABLES — the dump loaded without error and produced almost nothing, which is what an empty backup looks like"
  log "DRILL OK: $newest restored into a throwaway $DRILL_IMAGE, $tables tables, 0 errors (floor only: set DRILL_LIVE_CONTAINER to compare against the live schema instead)"
fi
date +%s > "$STATE_DIR/last-ok"
