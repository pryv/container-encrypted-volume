#!/usr/bin/env bash
# clevis key provider — unlock from a Clevis JWE (TPM2 / Tang / PKCS#11 / SSS).
#
# Create the JWE once (operator side), binding to a policy, e.g. TPM2:
#   head -c 32 /dev/urandom > rawkey
#   clevis encrypt tpm2 '{}' < rawkey > cev.jwe          # ship cev.jwe with the data
#   shred -u rawkey
# or Tang (network-bound):
#   clevis encrypt tang '{"url":"https://tang.example"}' < rawkey > cev.jwe
#
# At boot `clevis decrypt` reconstructs the key from the bound TPM/Tang server.
set -euo pipefail
die() { printf 'key/clevis: ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  resolve)
    : "${CEV_KEYFILE:?}"
    : "${CEV_CLEVIS_JWE:?CEV_CLEVIS_JWE (path to the Clevis JWE) is not set}"
    [ -r "$CEV_CLEVIS_JWE" ] || die "cannot read CEV_CLEVIS_JWE ($CEV_CLEVIS_JWE)"
    command -v clevis >/dev/null 2>&1 || die "clevis not found in image"
    clevis decrypt < "$CEV_CLEVIS_JWE" > "$CEV_KEYFILE" 2>/dev/null \
      || die "clevis decrypt failed (TPM/Tang policy not satisfied?)"
    ;;
  *) die "unknown verb '${1:-}' (expected: resolve)" ;;
esac
