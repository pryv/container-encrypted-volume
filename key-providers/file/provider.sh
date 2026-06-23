#!/usr/bin/env bash
# file key provider — key from a file ($CEV_KEY_FILE), base64 by default.
set -euo pipefail
die() { printf 'key/file: ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  resolve)
    : "${CEV_KEYFILE:?}"
    : "${CEV_KEY_FILE:?CEV_KEY_FILE is not set}"
    [ -r "$CEV_KEY_FILE" ] || die "cannot read $CEV_KEY_FILE"
    if [ "${CEV_KEY_FILE_RAW:-false}" = "true" ]; then
      cat "$CEV_KEY_FILE" > "$CEV_KEYFILE"
    else
      base64 -d < "$CEV_KEY_FILE" > "$CEV_KEYFILE" 2>/dev/null \
        || die "$CEV_KEY_FILE is not valid base64 (set CEV_KEY_FILE_RAW=true for raw bytes)"
    fi
    ;;
  *) die "unknown verb '${1:-}' (expected: resolve)" ;;
esac
