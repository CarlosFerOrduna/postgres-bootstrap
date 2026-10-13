#!/usr/bin/env bash
# Snapshot one or more Postgres databases into dumps/<label>-<UTC timestamp>/<db>.dump.
# The source side only ever runs pg_dump: nothing is written to the source server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF
Usage: docker compose run --rm snapshot pull <source> [options]

Sources:
  docker:<container>           pg_dump inside a local container (uses its POSTGRES_USER);
                               needs the Docker socket (see docker-compose.override.yml.example)
  ssh:<host>:<container>       pg_dump inside a container on a remote host, streamed over SSH
  ssh:<host>                   the remote host's own pg_dump (user from SRC_PGUSER, optional)
  url:postgres://user@host:port
                               pg_dump straight from this container; password from SRC_PGPASSWORD
  file:<path>                  copy an existing .dump (custom format) or .sql (plain) file;
                               the path is relative to the project directory

Options:
  --db <db1,db2>               databases to dump (default: DATABASES from env or .env)
  --schema-only                dump schema only, no data
  --exclude-table-data <t1,t2> tables whose data is skipped
                               (default: EXCLUDE_TABLE_DATA from env or .env)
  --include-all-data           dump every table's data, ignoring the exclusion list
  --restore                    run restore.sh with the new snapshot when done
  -h, --help                   show this help

Output: dumps/<label>-<yyyymmddTHHMMSSZ>/<db>.dump (or <db>.sql for plain file sources)
EOF
}

sanitize_label() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# --- Arguments -------------------------------------------------------------

[[ $# -gt 0 ]] || { usage; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

SOURCE="$1"
shift

DBS="$(config_var DATABASES)"
DB_FLAG_GIVEN=false
SCHEMA_ONLY=false
INCLUDE_ALL_DATA=false
RUN_RESTORE=false
EXCLUDE_TABLE_DATA="$(config_var EXCLUDE_TABLE_DATA)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      [[ $# -ge 2 ]] || die "--db needs a value"
      DBS="$2"; DB_FLAG_GIVEN=true; shift 2 ;;
    --schema-only)
      SCHEMA_ONLY=true; shift ;;
    --exclude-table-data)
      [[ $# -ge 2 ]] || die "--exclude-table-data needs a value"
      EXCLUDE_TABLE_DATA="$2"; shift 2 ;;
    --include-all-data)
      INCLUDE_ALL_DATA=true; shift ;;
    --restore)
      RUN_RESTORE=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1 (see --help)" ;;
  esac
done

DB_LIST=()
[[ -z "$DBS" ]] || IFS=',' read -r -a DB_LIST <<< "$DBS"
for db in ${DB_LIST[@]+"${DB_LIST[@]}"}; do
  [[ -n "$db" ]] || die "Empty database name in '$DBS'"
done

# --- pg_dump arguments shared by every remote source -----------------------

PG_DUMP_ARGS=(-Fc)
EXCLUDED_TABLES=()
if [[ "$SCHEMA_ONLY" == true ]]; then
  PG_DUMP_ARGS+=(--schema-only)
elif [[ "$INCLUDE_ALL_DATA" == false && -n "$EXCLUDE_TABLE_DATA" ]]; then
  IFS=',' read -r -a EXCLUDED_TABLES <<< "$EXCLUDE_TABLE_DATA"
  for table in "${EXCLUDED_TABLES[@]}"; do
    [[ -n "$table" ]] && PG_DUMP_ARGS+=("--exclude-table-data=$table")
  done
fi

# --- Source parsing --------------------------------------------------------

SOURCE_KIND="${SOURCE%%:*}"
SOURCE_SPEC="${SOURCE#*:}"
[[ "$SOURCE" == *:* && -n "$SOURCE_SPEC" ]] || die "Invalid source '$SOURCE' (see --help)"

if [[ "$SOURCE_KIND" != file && ${#DB_LIST[@]} -eq 0 ]]; then
  die "No databases to dump: pass --db <db1,db2> or set DATABASES in .env"
fi

SSH_HOST=""
SSH_CONTAINER=""
URL_USER=""
URL_HOST=""
URL_PORT=""

case "$SOURCE_KIND" in
  docker)
    docker version >/dev/null 2>&1 \
      || die "docker: sources need the Docker socket; enable it in docker-compose.override.yml"
    LABEL="$SOURCE_SPEC"
    ;;
  ssh)
    command -v ssh >/dev/null || die "ssh is not on PATH"
    if [[ "$SOURCE_SPEC" == *:* ]]; then
      SSH_HOST="${SOURCE_SPEC%%:*}"
      SSH_CONTAINER="${SOURCE_SPEC#*:}"
      LABEL="${SSH_HOST#*@}-$SSH_CONTAINER"
    else
      SSH_HOST="$SOURCE_SPEC"
      LABEL="${SSH_HOST#*@}"
    fi
    [[ -n "$SSH_HOST" ]] || die "ssh source needs a host"
    ;;
  url)
    url_rest="${SOURCE_SPEC#postgres://}"
    url_rest="${url_rest#postgresql://}"
    url_rest="${url_rest%%/*}"
    [[ "$url_rest" == *@* ]] || die "url source needs a user: url:postgres://user@host:port"
    url_userinfo="${url_rest%@*}"
    [[ "$url_userinfo" != *:* ]] || die "Do not put the password in the URL; export SRC_PGPASSWORD instead"
    URL_USER="$url_userinfo"
    url_hostport="${url_rest##*@}"
    URL_HOST="${url_hostport%%:*}"
    URL_PORT=5432
    [[ "$url_hostport" == *:* ]] && URL_PORT="${url_hostport##*:}"
    [[ -n "$URL_USER" && -n "$URL_HOST" ]] || die "Invalid url source (expected url:postgres://user@host:port)"
    [[ -n "${SRC_PGPASSWORD:-}" ]] || echo "⚠️  SRC_PGPASSWORD is not set; pg_dump will fail if the server requires a password"
    LABEL="$URL_HOST"
    ;;
  file)
    [[ -f "$SOURCE_SPEC" ]] || die "File not found: $SOURCE_SPEC"
    LABEL="file"
    ;;
  *)
    die "Unknown source type '$SOURCE_KIND' (expected docker, ssh, url or file)"
    ;;
esac

SNAPSHOT_DIR="$DUMPS_DIR/$(sanitize_label "$LABEL")-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SNAPSHOT_DIR"

snapshot_complete=false
cleanup_partial_snapshot() {
  if [[ "$snapshot_complete" == false ]]; then
    rm -rf "$SNAPSHOT_DIR"
    echo "🧹 Removed incomplete snapshot $SNAPSHOT_DIR" >&2
  fi
}
trap cleanup_partial_snapshot EXIT

# --- File source -----------------------------------------------------------

pull_file() {
  local path="$SOURCE_SPEC" base ext db
  base="$(basename "$path")"
  ext="${base##*.}"
  case "$ext" in
    dump)
      [[ "$(head -c 5 "$path")" == "PGDMP" ]] || die "$path is not a pg_dump custom-format archive"
      ;;
    sql)
      # A plain dump with CREATE DATABASE / \connect would write to the wrong database on restore
      if grep -qE '^(CREATE DATABASE|\\connect)' "$path"; then
        die "$path contains CREATE DATABASE or \\connect; re-dump it without -C/--create"
      fi
      ;;
    *)
      die "Unsupported file extension '.$ext' (expected .dump or .sql)"
      ;;
  esac

  # The file name sets the target database, unless --db names it explicitly
  if [[ "$DB_FLAG_GIVEN" == true ]]; then
    [[ ${#DB_LIST[@]} -eq 1 ]] || die "file source takes exactly one --db"
    db="${DB_LIST[0]}"
  else
    db="${base%.*}"
  fi

  echo "📦 Copying $path → $SNAPSHOT_DIR/$db.$ext"
  cp "$path" "$SNAPSHOT_DIR/$db.$ext"
}

# --- Dump sources ----------------------------------------------------------

# Writes one database's pg_dump to stdout, according to the chosen source
dump_db_to_stdout() {
  local db="$1" remote_cmd
  case "$SOURCE_KIND" in
    docker)
      docker exec "$SOURCE_SPEC" sh -c 'exec pg_dump -U "${POSTGRES_USER:-postgres}" "$@"' \
        sh "${PG_DUMP_ARGS[@]}" "$db"
      ;;
    ssh)
      if [[ -n "$SSH_CONTAINER" ]]; then
        # Single quotes on purpose: POSTGRES_USER expands inside the remote container
        # shellcheck disable=SC2016
        printf -v remote_cmd '%q ' docker exec "$SSH_CONTAINER" sh -c \
          'exec pg_dump -U "${POSTGRES_USER:-postgres}" "$@"' sh "${PG_DUMP_ARGS[@]}" "$db"
      elif [[ -n "${SRC_PGUSER:-}" ]]; then
        printf -v remote_cmd '%q ' pg_dump -U "$SRC_PGUSER" "${PG_DUMP_ARGS[@]}" "$db"
      else
        printf -v remote_cmd '%q ' pg_dump "${PG_DUMP_ARGS[@]}" "$db"
      fi
      # remote_cmd is already escaped with %q for the remote shell
      # shellcheck disable=SC2029
      ssh "$SSH_HOST" "$remote_cmd"
      ;;
    url)
      PGPASSWORD="${SRC_PGPASSWORD:-}" pg_dump -h "$URL_HOST" -p "$URL_PORT" -U "$URL_USER" "${PG_DUMP_ARGS[@]}" "$db"
      ;;
  esac
}

# pg_restore adds constraints after loading data, so a foreign key into a table whose data was
# skipped fails the restore as soon as the referencing table has rows. Read from the dump itself,
# so the source still only ever sees pg_dump.
warn_about_fks_into_excluded_tables() {
  local dump="$1" db="$2" line referencing="" referenced candidate pattern
  local alter_table_regex='^ALTER TABLE (ONLY )?([^ ]+)'
  local foreign_key_regex='FOREIGN KEY.*REFERENCES ([^(]+)[(]'
  local quote='"'
  while IFS= read -r line; do
    if [[ "$line" =~ $alter_table_regex ]]; then
      referencing="${BASH_REMATCH[2]//$quote/}"
    elif [[ "$line" =~ $foreign_key_regex ]]; then
      referenced="${BASH_REMATCH[1]//$quote/}"
      for pattern in "${EXCLUDED_TABLES[@]}"; do
        [[ -n "$pattern" ]] || continue
        # Unqualified patterns match the table in any schema, as in pg_dump
        candidate="$referenced"
        [[ "$pattern" == *.* ]] || candidate="${referenced##*.}"
        # shellcheck disable=SC2053 # the pattern is a glob on purpose, like pg_dump's
        if [[ "$candidate" == $pattern && "$referencing" != "$referenced" ]]; then
          echo "⚠️  $db: $referencing has a foreign key into $referenced, whose data is excluded;" \
            "the restore fails if $referencing has rows. Exclude $referencing's data too."
        fi
      done
    fi
  done < <(pg_restore --section=post-data -f - "$dump")
}

pull_dumps() {
  local db target
  for db in "${DB_LIST[@]}"; do
    target="$SNAPSHOT_DIR/$db.dump"
    echo "⏳ Dumping $db from $SOURCE_KIND:$LABEL..."
    dump_db_to_stdout "$db" > "$target"
    [[ "$(head -c 5 "$target")" == "PGDMP" ]] || die "$db dump is not a valid custom-format archive"
    echo "✅ $db → $target ($(du -h "$target" | cut -f1))"
    if [[ ${#EXCLUDED_TABLES[@]} -gt 0 ]]; then
      warn_about_fks_into_excluded_tables "$target" "$db"
    fi
  done
}

if [[ "$SCHEMA_ONLY" == true ]]; then
  echo "🧩 Schema only"
elif [[ "$INCLUDE_ALL_DATA" == true ]]; then
  echo "🧩 Including data for every table"
elif [[ -n "$EXCLUDE_TABLE_DATA" ]]; then
  echo "🧩 Skipping data for: $EXCLUDE_TABLE_DATA"
fi

if [[ "$SOURCE_KIND" == file ]]; then
  pull_file
else
  pull_dumps
fi

snapshot_complete=true
echo "🎉 Snapshot ready: $SNAPSHOT_DIR"

if [[ "$RUN_RESTORE" == true ]]; then
  exec bash "$SCRIPT_DIR/restore.sh" "$SNAPSHOT_DIR"
fi
