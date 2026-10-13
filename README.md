# postgres-bootstrap

A Docker Compose stack that runs a local **PostgreSQL** server, plus an on-demand `snapshot`
service to refresh it from any other Postgres — a local container, a container on a remote
host, any reachable server, or a dump file — without wiping the volume.

Everything runs in containers, so the only host requirement is Docker. The same commands
work from PowerShell, cmd, macOS and Linux shells.

- `pull` snapshots a source into `dumps/<label>-<UTC timestamp>/<db>.dump`. It only ever
  runs `pg_dump` against the source — never `psql`, `pg_restore`, or any write.
- `restore` loads a snapshot into this stack's **running** `postgres` service, replacing
  each database. It can't point anywhere else.

## Why

`docker-entrypoint-initdb.d` scripts only run on an **empty volume**, so refreshing data
usually means a hand-made dump, editing the SQL, then `docker compose down -v` + `up`. Here
it is one command, and ownership comes out right even when the source used other roles.

## Requirements

- Docker + Docker Compose v2

> Snapshots are **not** versioned — `dumps/`, `*.dump` and `*.sql` are git-ignored. They hold
> real data. So is `init/`: init scripts usually carry passwords.

## Quick start

```bash
# 1. Configure
cp .env.example .env
#    edit .env: set POSTGRES_PASSWORD, and DATABASES / DB_OWNERS for your databases

# 2. Start the server
docker compose up -d

# 3. Pull a source and load it
docker compose run --rm snapshot pull url:postgres://readonly@db.example.internal:5432 --restore
```

`pull ... --restore` is the same as `pull ...` followed by `restore <new snapshot>`. The first
`run` builds the `snapshot` image; it is rebuilt only when `snapshot.Dockerfile` or
`POSTGRES_IMAGE` change. Scripts are mounted, not baked in, so editing them needs no rebuild.

## Services

| Service    | Purpose                                                                      |
| ---------- | ---------------------------------------------------------------------------- |
| `postgres` | The server. Data persists in the `postgres_data` volume.                     |
| `snapshot` | On-demand tooling (profile `tools`): never started by `up`, only by `run`.   |

`snapshot` is built from `POSTGRES_IMAGE`, so its `pg_dump`/`pg_restore` match the server,
plus `ssh` and the `docker` CLI. It shares `postgres`' network namespace
(`network_mode: service:postgres`): `restore` always connects to `127.0.0.1:5432`, which can
only be this stack's server — even if another `postgres` lives on a shared network. Sources
are reached through the same networks `postgres` is on.

## Configuration

Everything lives in `.env`, which both services load.

| Variable             | Default         | Purpose                                                          |
| -------------------- | --------------- | ---------------------------------------------------------------- |
| `POSTGRES_USER`      | —               | Superuser created on first boot; `restore` runs as it.           |
| `POSTGRES_PASSWORD`  | —               | Its password.                                                    |
| `POSTGRES_IMAGE`     | `postgres:16.3` | Image for the server and the `snapshot` tooling.                 |
| `PG_PORT`            | `5432`          | Host port to publish.                                            |
| `DATABASES`          | —               | Databases `pull` dumps when `--db` is not given.                 |
| `DB_OWNERS`          | —               | `db:role,db:role`. Owner role per database for `restore`.        |
| `EXCLUDE_TABLE_DATA` | —               | Tables whose **data** `pull` skips (heavy or PII tables).        |

Two more are passed through from your shell only, so they never sit in `.env`:

| Variable         | Purpose                                 |
| ---------------- | --------------------------------------- |
| `SRC_PGPASSWORD` | Password for `url:` sources.            |
| `SRC_PGUSER`     | User for `ssh:<host>` (no container).   |

Lists are comma-separated, with no spaces around the commas.

## Sources

### `url:postgres://user@host:port` — any reachable server

```bash
# bash / zsh
export SRC_PGPASSWORD='...'
# PowerShell
$env:SRC_PGPASSWORD = '...'

docker compose run --rm snapshot pull url:postgres://readonly@db.example.internal:5432
```

Runs `pg_dump` from the `snapshot` container. The password comes **only** from
`SRC_PGPASSWORD`; a URL containing a password is rejected. Any database path in the URL is
ignored — `--db` / `DATABASES` select the databases.

To reach another container by name, put this stack on a network it is on (see
[Using it with other containers](#using-it-with-other-containers)). To reach a port on your
own machine with Docker Desktop, use `host.docker.internal`. For a server only reachable
through SSH, open a tunnel on the host and point the URL at it:

```bash
ssh -N -L 15432:db.internal:5432 deploy@bastion
docker compose run --rm snapshot pull url:postgres://readonly@host.docker.internal:15432
```

### `docker:<container>` — a local container

```bash
docker compose run --rm snapshot pull docker:my-other-postgres --db app_db
```

Runs `docker exec <container> pg_dump -U "$POSTGRES_USER"`, using the container's own
`POSTGRES_USER` and local-socket trust: no password, and the container can be on any network.
**Needs the Docker socket**, which is off by default — see
[Optional mounts](#optional-mounts).

### `ssh:<host>:<container>` — a container on a remote host

```bash
docker compose run --rm snapshot pull ssh:deploy@dev-box:postgres
```

Runs the same `docker exec ... pg_dump` on the remote host. The dump streams back over the
SSH session's stdout: no remote files, no tunnel. `<host>` is anything `ssh` accepts,
including aliases from `~/.ssh/config`. **Needs your `~/.ssh`**, which is off by default — see
[Optional mounts](#optional-mounts).

`ssh:<host>` without a container runs the remote's own `pg_dump`; set `SRC_PGUSER` and make
sure the remote can authenticate it (peer auth or `~/.pgpass`).

### `file:<path>` — an existing dump

```bash
docker compose run --rm snapshot pull file:dumps/app_db.dump
docker compose run --rm snapshot pull file:backup.sql --db app_db
```

Copies the file into a new snapshot so `restore` treats it like any other source. The path is
**relative to this directory** (it is mounted at `/work`), so copy the file in first.

- `.dump` must be `pg_dump -Fc` (custom format).
- `.sql` must be a plain per-database dump **without** `CREATE DATABASE` / `\connect`
  (i.e. `pg_dump` without `-C`).
- The target database is the file name (`app_db.dump` → `app_db`) unless you pass one `--db`.

## Options (`pull`)

| Option                         | Effect                                                         |
| ------------------------------ | -------------------------------------------------------------- |
| `--db db1,db2`                 | Databases to dump. Default: `DATABASES`.                       |
| `--schema-only`                | Schema only, no data.                                          |
| `--exclude-table-data t1,t2`   | Skip these tables' data (overrides `EXCLUDE_TABLE_DATA`).      |
| `--include-all-data`           | Dump every table's data, ignoring the exclusion list.          |
| `--restore`                    | Run `restore` on the new snapshot when done.                   |

Excluded tables keep their schema; they just come back empty. Names follow `pg_dump`
patterns, so `audit_log` matches in any schema and `sales.audit_log` in one.

## How the restore works

```bash
docker compose run --rm snapshot restore                                   # most recent
docker compose run --rm snapshot restore dumps/my-other-postgres-20260101T120000Z
```

For each `<db>.dump` / `<db>.sql` in the snapshot:

1. If `DB_OWNERS` maps the database to a role, ensures the role exists. A role it has to
   create gets **no password** — a warning tells you to set one.
2. `DROP DATABASE IF EXISTS <db> WITH (FORCE)` (kicks connected clients), then
   `CREATE DATABASE <db>`, owned by that role or by `POSTGRES_USER`.
3. Loads the data: `pg_restore --no-owner --no-privileges --exit-on-error` (as the owner
   role, via `--role`) for `.dump`, `psql -v ON_ERROR_STOP=1` for `.sql`.
4. With an owner role, reassigns every schema, table, view, sequence, enum, domain and
   function to it — skipping objects that belong to extensions. This is what fixes plain
   `.sql` dumps, which load as the superuser.

It ends with an exact row count per table.

The source's own roles and grants are not carried over (`--no-owner --no-privileges`): the
local copy is owned by the roles you map, whatever the source used.

## Using it with other containers

By default the stack creates its own network and the server is reachable from the host at
`localhost:${PG_PORT}`. To let other containers reach it by name — or to reach source
containers by name in `url:` — join a shared network:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
# uncomment the network block (and container_name, if you want a fixed hostname)
docker network create my-shared-network
```

`docker-compose.override.yml` is git-ignored, so machine-specific wiring never lands in the
repo.

## Optional mounts

Both live in `docker-compose.override.yml` (see the example file), under `snapshot.volumes`:

| Mount                                         | Enables          | Trade-off                                                  |
| --------------------------------------------- | ---------------- | ---------------------------------------------------------- |
| `/var/run/docker.sock:/var/run/docker.sock`   | `docker:` sources | Gives the container full control of the host's Docker.    |
| `~/.ssh:/ssh-src:ro`                          | `ssh:` sources    | Exposes your keys to the container, read-only.            |

Keys are copied into the container with `600` permissions on start, so Windows mounts — which
`ssh` would otherwise reject as too open — work as-is. `~/.ssh/config` entries pointing to
Windows paths (`C:\...`) won't resolve inside the container; use relative `IdentityFile`
paths like `~/.ssh/id_ed25519`.

## Init scripts

Anything in `init/` (`*.sql`, `*.sh`) runs once, on the first boot of an empty volume — use
it for roles and seed data. It is git-ignored apart from `.gitkeep`.

## Safety

- `pull` is read-only against the source: it only runs `pg_dump`.
- `restore` **destroys** the local databases it restores. Pull a snapshot of the local server
  first (`url:postgres://<POSTGRES_USER>@127.0.0.1:5432`) if you want to keep the current state.
- Passwords are never logged, never accepted in a URL, and never passed as arguments.
- A failed pull deletes its partial snapshot directory.
- The scripts refuse to run outside the `snapshot` container.

## Troubleshooting

**`pg_dump: error: aborting because of server version mismatch`.** `pg_dump` must be at
least the source server's version. Raise `POSTGRES_IMAGE` (server and tooling move together)
and rebuild with `docker compose build snapshot`. `docker:`/`ssh:` sources use the source
container's own `pg_dump` and are unaffected.

**`docker: sources need the Docker socket`.** Mount it in `docker-compose.override.yml`
(see [Optional mounts](#optional-mounts)).

**`Run this through the snapshot service`.** The scripts were run on the host; use
`docker compose run --rm snapshot <pull|restore> ...`.

**`pg_restore: error: could not execute query`.** `--exit-on-error` stops at the first
failure, leaving that database partially loaded. Fix the cause and run `restore` again — it
recreates the database from scratch. A common cause is an extension the local image doesn't
ship: match `POSTGRES_IMAGE` to the source.

**Snapshots owned by root on Linux.** `pull` hands `dumps/` back to the owner of this
directory when it finishes; if a run was killed midway, `sudo chown -R $USER dumps`.

**Start completely from scratch** (re-runs `init/`, discards all data):

```bash
docker compose down -v
docker compose up -d
```
