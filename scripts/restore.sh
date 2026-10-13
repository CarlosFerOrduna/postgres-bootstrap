#!/usr/bin/env bash
# Load a snapshot from dumps/ into this stack's postgres service, replacing each database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$SCRIPT_DIR/common.sh"

# The snapshot service shares postgres' network (network_mode: service:postgres), so
# 127.0.0.1 is always this stack's postgres: the target can never be a remote database
TARGET_HOST="127.0.0.1"
TARGET_PORT="5432"

DB_OWNERS="$(config_var DB_OWNERS)"
POSTGRES_USER="$(config_var POSTGRES_USER postgres)"
POSTGRES_PASSWORD="$(config_var POSTGRES_PASSWORD)"

usage() {
  cat <<EOF
Usage: docker compose run --rm snapshot restore [dumps/<snapshot>]

Restores every <db>.dump / <db>.sql in the snapshot into this stack's postgres service.
Each database is dropped and recreated first.

Default snapshot: the most recent one under dumps/.
Owner roles come from DB_OWNERS (db:role,db:role) in env or .env; databases without an
entry stay owned by POSTGRES_USER.
EOF
}

# Owner role of a database per DB_OWNERS; empty when it is not mapped
owner_role_for() {
  local db="$1" pair
  local -a pairs=()
  [[ -z "$DB_OWNERS" ]] || IFS=',' read -r -a pairs <<< "$DB_OWNERS"
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    if [[ "${pair%%:*}" == "$db" ]]; then
      printf '%s' "${pair#*:}"
      return 0
    fi
  done
}

latest_snapshot() {
  local dir latest="" latest_ts="" ts
  for dir in "$DUMPS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    ts="${dir##*-}"
    if [[ -z "$latest_ts" || "$ts" > "$latest_ts" ]]; then
      latest="$dir"
      latest_ts="$ts"
    fi
  done
  printf '%s' "$latest"
}

# --- Arguments -------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[[ $# -le 1 ]] || { usage; exit 1; }

SNAPSHOT_DIR="${1:-$(latest_snapshot)}"
[[ -n "$SNAPSHOT_DIR" ]] || die "No snapshots under $DUMPS_DIR; run the pull command first"
[[ -d "$SNAPSHOT_DIR" ]] || die "Snapshot not found: $SNAPSHOT_DIR"
SNAPSHOT_DIR="${SNAPSHOT_DIR%/}"

shopt -s nullglob
SNAPSHOT_FILES=("$SNAPSHOT_DIR"/*.dump "$SNAPSHOT_DIR"/*.sql)
shopt -u nullglob
[[ ${#SNAPSHOT_FILES[@]} -gt 0 ]] || die "No .dump or .sql files in $SNAPSHOT_DIR"

# --- Target checks ---------------------------------------------------------

# Runs a Postgres client against this stack's postgres as POSTGRES_USER
target_pg() {
  local client="$1"
  shift
  PGPASSWORD="$POSTGRES_PASSWORD" "$client" -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$POSTGRES_USER" "$@"
}

target_psql() {
  target_pg psql -v ON_ERROR_STOP=1 -X -q "$@"
}

echo "⏳ Waiting for postgres to accept connections..."
for _ in $(seq 1 30); do
  target_pg pg_isready -q && break
  sleep 1
done
target_pg pg_isready -q || die "postgres is not ready"

echo "📦 Restoring snapshot $SNAPSHOT_DIR into postgres"

# --- Restore ---------------------------------------------------------------

ensure_role() {
  local role="$1" exists
  exists="$(target_psql -At -d postgres -v role="$role" <<'SQL'
SELECT 1 FROM pg_roles WHERE rolname = :'role';
SQL
)"
  [[ -z "$exists" ]] || return 0

  target_psql -d postgres -v role="$role" <<'SQL'
CREATE ROLE :"role" LOGIN;
SQL
  echo "⚠️  Created role $role without a password; set one with ALTER ROLE"
}

recreate_database() {
  local db="$1" role="$2" owner_clause=""
  [[ -z "$role" ]] || owner_clause='OWNER :"role"'
  # Over stdin each statement is its own transaction: DROP/CREATE DATABASE reject a transaction block
  target_psql -d postgres -v db="$db" -v role="$role" <<SQL
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db" $owner_clause TEMPLATE template0 ENCODING 'UTF8';
SQL
}

load_file() {
  local file="$1" db="$2" role="$3" role_args=()
  case "$file" in
    *.dump)
      [[ -z "$role" ]] || role_args=(--role="$role")
      target_pg pg_restore -d "$db" --no-owner --no-privileges --exit-on-error \
        ${role_args[@]+"${role_args[@]}"} < "$file"
      ;;
    *.sql)
      target_psql -d "$db" < "$file"
      ;;
  esac
}

# Reassigns everything the superuser created (plain .sql case) to the role, leaving
# extension objects alone. Sequences owned by a column follow their table.
fix_ownership() {
  local db="$1" role="$2"
  target_psql -d "$db" -v db="$db" -v role="$role" <<'SQL'
ALTER DATABASE :"db" OWNER TO :"role";

WITH user_schemas AS (
  SELECT oid, nspname
    FROM pg_namespace
   WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname NOT LIKE 'pg\_%'
),
extension_members AS (
  SELECT classid, objid FROM pg_depend WHERE deptype = 'e'
)
SELECT format('ALTER SCHEMA %I OWNER TO %I', s.nspname, :'role')
  FROM user_schemas s
 WHERE s.nspname <> 'public'
   AND NOT EXISTS (SELECT FROM extension_members e
                    WHERE e.classid = 'pg_namespace'::regclass AND e.objid = s.oid)
UNION ALL
SELECT format('ALTER TABLE %I.%I OWNER TO %I', s.nspname, c.relname, :'role')
  FROM pg_class c JOIN user_schemas s ON s.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
   AND NOT EXISTS (SELECT FROM extension_members e
                    WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid)
UNION ALL
SELECT format('ALTER SEQUENCE %I.%I OWNER TO %I', s.nspname, c.relname, :'role')
  FROM pg_class c JOIN user_schemas s ON s.oid = c.relnamespace
 WHERE c.relkind = 'S'
   AND NOT EXISTS (SELECT FROM pg_depend d
                    WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                      AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i'))
   AND NOT EXISTS (SELECT FROM extension_members e
                    WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid)
UNION ALL
SELECT format('ALTER TYPE %I.%I OWNER TO %I', s.nspname, t.typname, :'role')
  FROM pg_type t JOIN user_schemas s ON s.oid = t.typnamespace
 WHERE t.typtype IN ('e', 'd')
   AND NOT EXISTS (SELECT FROM extension_members e
                    WHERE e.classid = 'pg_type'::regclass AND e.objid = t.oid)
UNION ALL
SELECT format('ALTER ROUTINE %s OWNER TO %I', p.oid::regprocedure, :'role')
  FROM pg_proc p JOIN user_schemas s ON s.oid = p.pronamespace
 WHERE p.prokind IN ('f', 'p', 'w')
   AND NOT EXISTS (SELECT FROM extension_members e
                    WHERE e.classid = 'pg_proc'::regclass AND e.objid = p.oid)
\gexec
SQL
}

print_row_counts() {
  local db="$1"
  target_pg psql -X -d "$db" <<'SQL'
SELECT table_schema AS "schema",
       table_name AS "table",
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text::bigint AS rows
  FROM information_schema.tables
 WHERE table_type = 'BASE TABLE'
   AND table_schema NOT IN ('pg_catalog', 'information_schema')
 ORDER BY table_schema, table_name;
SQL
}

for file in "${SNAPSHOT_FILES[@]}"; do
  db="$(basename "${file%.*}")"
  role="$(owner_role_for "$db")"

  if [[ -n "$role" ]]; then
    echo "🔐 Ensuring role $role exists..."
    ensure_role "$role"
  fi

  echo "🗑️  Recreating $db (owner ${role:-POSTGRES_USER})..."
  recreate_database "$db" "$role"

  echo "⏳ Loading $(basename "$file") into $db..."
  load_file "$file" "$db" "$role"

  if [[ -n "$role" ]]; then
    echo "🔧 Fixing ownership in $db..."
    fix_ownership "$db" "$role"
  fi

  echo "✅ $db restored"
done

echo "📊 Row counts"
for file in "${SNAPSHOT_FILES[@]}"; do
  db="$(basename "${file%.*}")"
  echo "── $db"
  print_row_counts "$db"
done

echo "🎉 Restore complete"
