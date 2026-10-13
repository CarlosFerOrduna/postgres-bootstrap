#!/usr/bin/env bash
# Shared helpers for the snapshot scripts. Source it, do not run it.

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$COMMON_DIR")"
# Used by pull.sh and restore.sh after sourcing this file
# shellcheck disable=SC2034
DUMPS_DIR="$PROJECT_DIR/dumps"

die() {
  echo "❌ $*" >&2
  exit 1
}

# The tools (pg_dump, ssh, docker) and the 127.0.0.1 target only exist inside the service
if [[ "${SNAPSHOT_IN_CONTAINER:-}" != 1 ]]; then
  die "Run this through the snapshot service: docker compose run --rm snapshot <pull|restore> ..."
fi

# Reads a single key from .env without sourcing it: the file is a compose env_file, not bash
read_env_file_var() {
  local key="$1" env_file="$PROJECT_DIR/.env"
  [[ -f "$env_file" ]] || return 0
  { grep -E "^${key}=" "$env_file" || true; } | tail -n 1 | cut -d= -f2- | tr -d '\r' \
    | sed -e 's/^"//' -e 's/"$//'
}

# Config value: environment variable first, then .env, then the default
config_var() {
  local key="$1" default="${2:-}" value
  value="${!key:-}"
  [[ -n "$value" ]] || value="$(read_env_file_var "$key")"
  printf '%s' "${value:-$default}"
}
