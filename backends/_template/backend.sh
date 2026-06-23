#!/usr/bin/env bash
#
# Backend template — copy this directory to backends/<your-name>/, fill in the
# verbs, declare your manifest, and pass: test/conformance.sh <your-name>.
#
# CONTRACT — every verb MUST honour these invariants:
#   preflight      verify the runtime grants manifest.requires; non-zero + a
#                  human message naming what's missing if not.
#   provision      IDEMPOTENT — create the encrypted container if absent; exit 0
#                  if already provisioned. Never overwrite foreign data.
#   open           IDEMPOTENT — after success $CEV_MOUNT is a mounted writable fs;
#                  exit 0 if already mounted. Format the fs on first open only.
#   close          IDEMPOTENT — after success the container is ciphertext at rest;
#                  exit 0 if already closed.
#   status         machine-readable; MUST NOT mutate state.
#   rotate         swap the unlock key ($CEV_KEYFILE -> $CEV_NEW_KEYFILE). If your
#                  backend cannot do this without re-encrypting, say so and set
#                  capabilities.rotateWithoutReencrypt=false in the manifest.
#   header-backup  emit recovery metadata to $CEV_HEADER_BACKUP. If there is no
#                  separable header, no-op with a printed note and set
#                  capabilities.separableHeaderBackup=false.
#   grow           expand to $CEV_SIZE_GIB if capabilities.growInPlace; else exit
#                  non-zero with a clear message.
#
# Env contract (provided by cev.sh): CEV_CONTAINER CEV_MOUNT CEV_KEYFILE
#   CEV_SIZE_GIB CEV_MAP_NAME CEV_NEW_KEYFILE CEV_HEADER_BACKUP
# The key is in a file ($CEV_KEYFILE); NEVER place key material on argv or in logs.
set -euo pipefail
die() { printf '%s: ERROR: %s\n' "$(basename "$(dirname "$0")")" "$*" >&2; exit 1; }

case "${1:-}" in
  preflight)     die "not implemented" ;;
  provision)     die "not implemented" ;;
  open)          die "not implemented" ;;
  close)         die "not implemented" ;;
  status)        die "not implemented" ;;
  rotate)        die "not implemented" ;;
  header-backup) die "not implemented" ;;
  grow)          die "not implemented" ;;
  *) die "unknown verb '${1:-}'" ;;
esac
