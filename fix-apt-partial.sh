#!/usr/bin/env bash
set -euo pipefail

# Fixes apt errors like:
#   E: List directory /var/lib/apt/lists/partial is missing. - Acquire (30: Read-only file system)
#
# Behavior:
# - If /var/lib/apt/lists is writable, recreate and fix the standard partial directory.
# - If it is read-only, run apt using writable temp state/cache directories.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'USAGE'
Usage: ./fix-apt-partial.sh [apt-get args]

Examples:
  ./fix-apt-partial.sh update
  ./fix-apt-partial.sh install -y curl

If no args are provided, defaults to: update
USAGE
  exit 0
fi

if touch /var/lib/apt/lists/.codex_rw_test 2>/dev/null; then
  rm -f /var/lib/apt/lists/.codex_rw_test
  mkdir -p /var/lib/apt/lists/partial
  chown _apt:root /var/lib/apt/lists/partial || true
  chmod 700 /var/lib/apt/lists/partial || true
  apt-get "${@:-update}"
else
  STATE_DIR="${APT_STATE_DIR:-/tmp/apt-state/lists}"
  CACHE_DIR="${APT_CACHE_DIR:-/tmp/apt-cache/archives}"

  mkdir -p "$STATE_DIR/partial" "$CACHE_DIR/partial"

  apt-get \
    -o Dir::State::lists="$STATE_DIR" \
    -o Dir::Cache::archives="$CACHE_DIR" \
    "${@:-update}"
fi
