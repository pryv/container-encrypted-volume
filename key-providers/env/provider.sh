#!/usr/bin/env bash
# env key provider — key from $CEV_KEY (base64 of 32 bytes).
# Writes raw key bytes to $CEV_KEYFILE. Never echoes the key.
set -euo pipefail
die() { printf 'key/env: ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  resolve)
    : "${CEV_KEYFILE:?}"
    [ -n "${CEV_KEY:-}" ] || die "CEV_KEY is not set (base64 of 32 bytes)"
    printf '%s' "$CEV_KEY" | base64 -d > "$CEV_KEYFILE" 2>/dev/null \
      || die "CEV_KEY is not valid base64"
    ;;
  *) die "unknown verb '${1:-}' (expected: resolve)" ;;
esac
