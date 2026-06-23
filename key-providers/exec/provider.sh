#!/usr/bin/env bash
# exec key provider — key from the stdout of $CEV_KEY_COMMAND (base64).
# The command is operator-supplied configuration (trusted). Output is captured
# in memory and decoded to $CEV_KEYFILE; the key never appears on argv.
set -euo pipefail
die() { printf 'key/exec: ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  resolve)
    : "${CEV_KEYFILE:?}"
    : "${CEV_KEY_COMMAND:?CEV_KEY_COMMAND is not set}"
    out="$(eval "$CEV_KEY_COMMAND")" || die "CEV_KEY_COMMAND failed"
    printf '%s' "$out" | tr -d '\r\n' | base64 -d > "$CEV_KEYFILE" 2>/dev/null \
      || die "CEV_KEY_COMMAND output is not valid base64"
    unset out
    ;;
  *) die "unknown verb '${1:-}' (expected: resolve)" ;;
esac
