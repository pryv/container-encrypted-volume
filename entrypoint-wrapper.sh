#!/usr/bin/env bash
#
# entrypoint-wrapper.sh — bring up the encrypted volume, point the application's
# data roots at it, then hand off to the application entrypoint.
#
# Layer this as the ENTRYPOINT of an image built FROM an application image:
#
#   ENTRYPOINT ["/opt/cev/entrypoint-wrapper.sh"]
#   ENV CEV_ENABLED=true CEV_BACKEND=luks CEV_KEY_PROVIDER=aws-kms \
#       CEV_MOUNT=/app/var-pryv/encrypted/mnt \
#       CEV_EXPORTS="PRYV_DATADIR=data" \
#       CEV_EXEC=/app/scripts/docker-entrypoint.sh
#
# When CEV_ENABLED != true this is a transparent pass-through, so the same image
# runs with or without encryption.
#
# Note: with block backends (LUKS) the container file is ciphertext on disk at
# ALL times — unlocking creates an in-kernel device mapping, it does not rewrite
# the file. So "ciphertext at rest" holds even after an unclean stop / power loss;
# no shutdown hook is required for the at-rest guarantee, and we exec the app
# directly (correct PID 1 signal + reaping semantics).
set -euo pipefail

CEV_HOME="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
log() { printf 'cev-entrypoint: %s\n' "$*" >&2; }

if [ "${CEV_ENABLED:-false}" = "true" ]; then
  "$CEV_HOME/cev.sh" up

  # Create and export the application data roots inside the encrypted mount.
  # CEV_EXPORTS is a space-separated list of VAR=subpath entries.
  if [ -n "${CEV_EXPORTS:-}" ]; then
    mount_root="${CEV_MOUNT:-/var/lib/cev/mnt}"
    for spec in $CEV_EXPORTS; do
      var="${spec%%=*}"; sub="${spec#*=}"
      target="$mount_root/$sub"
      mkdir -p "$target"
      export "$var=$target"
      log "exported $var=$target"
    done
  fi
else
  log "CEV_ENABLED!=true — encryption off, starting application directly"
fi

if [ -n "${CEV_EXEC:-}" ]; then
  exec "$CEV_EXEC" "$@"
else
  exec "$@"
fi
