#!/usr/bin/env bash
#
# Key-provider template — copy to key-providers/<your-name>/, implement resolve.
#
# CONTRACT:
#   resolve   Write exactly 32 raw key bytes to the file named by $CEV_KEYFILE.
#             Return non-zero on any failure. NEVER print the key or place it on
#             argv. For envelope providers (manifest.envelope=true): read the
#             wrapped blob, call the external KMS/HSM to unwrap using the
#             container's identity (IAM role / Workload Identity / cert), and
#             write the 32 plaintext bytes to $CEV_KEYFILE.
#
# cev.sh validates the 32-byte length and optionally HKDF-derives afterwards, so
# providers only need to deliver the raw key material.
set -euo pipefail
die() { printf 'key/%s: ERROR: %s\n' "$(basename "$(dirname "$0")")" "$*" >&2; exit 1; }

case "${1:-}" in
  resolve)
    : "${CEV_KEYFILE:?}"
    die "not implemented — write 32 raw key bytes to \$CEV_KEYFILE"
    ;;
  *) die "unknown verb '${1:-}' (expected: resolve)" ;;
esac
