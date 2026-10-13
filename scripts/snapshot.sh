#!/usr/bin/env bash
# Entrypoint of the snapshot service: docker compose run --rm snapshot <pull|restore> [args]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF
Usage: docker compose run --rm snapshot <command> [args]

Commands:
  pull <source> [options]   snapshot a source into dumps/ (see: pull --help)
  restore [dumps/<snap>]    load a snapshot into this stack's postgres (see: restore --help)
  help                      show this help
EOF
}

# Keys mounted from Windows/macOS arrive with permissions ssh rejects: copy and tighten them
prepare_ssh() {
  [[ -d /ssh-src ]] || return 0
  mkdir -p "$HOME/.ssh"
  cp -r /ssh-src/. "$HOME/.ssh/"
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type f -exec chmod 600 {} +
}

# The container runs as root: hand snapshots back to the project directory's owner on the host
restore_dumps_ownership() {
  [[ -d "$DUMPS_DIR" ]] || return 0
  chown -R "$(stat -c '%u:%g' "$PROJECT_DIR")" "$DUMPS_DIR" 2>/dev/null || true
}

command="${1:-help}"
[[ $# -eq 0 ]] || shift

case "$command" in
  pull)
    prepare_ssh
    trap restore_dumps_ownership EXIT
    bash "$SCRIPT_DIR/pull.sh" "$@"
    ;;
  restore)
    bash "$SCRIPT_DIR/restore.sh" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "Unknown command: $command"
    ;;
esac
