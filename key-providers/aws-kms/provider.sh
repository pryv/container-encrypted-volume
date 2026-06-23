#!/usr/bin/env bash
# aws-kms key provider (envelope) — unwrap a KMS-encrypted data key at boot.
#
# Create the wrapped blob once (operator side):
#   head -c 32 /dev/urandom > rawkey                 # the 32-byte unlock key
#   aws kms encrypt --key-id alias/cev --region eu-central-2 \
#     --plaintext fileb://rawkey --query CiphertextBlob --output text \
#     | base64 -d > cev.blob                          # ship cev.blob with the data
#   shred -u rawkey
#
# At boot AWS KMS decrypts cev.blob authorized by the container's AWS identity
# (task/instance IAM role, or IAM Roles Anywhere on non-AWS hosts e.g. Exoscale).
set -euo pipefail
die() { printf 'key/aws-kms: ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  resolve)
    : "${CEV_KEYFILE:?}"
    : "${CEV_KMS_BLOB:?CEV_KMS_BLOB (path to the wrapped data-key blob) is not set}"
    [ -r "$CEV_KMS_BLOB" ] || die "cannot read CEV_KMS_BLOB ($CEV_KMS_BLOB)"
    command -v aws >/dev/null 2>&1 || die "aws CLI not found in image"
    region=(); [ -n "${CEV_AWS_REGION:-}" ] && region=(--region "$CEV_AWS_REGION")
    # KMS returns the plaintext base64-encoded in --output text.
    pt="$(aws kms decrypt "${region[@]}" \
            --ciphertext-blob "fileb://$CEV_KMS_BLOB" \
            --query Plaintext --output text)" || die "aws kms decrypt failed (identity/permissions?)"
    printf '%s' "$pt" | base64 -d > "$CEV_KEYFILE" 2>/dev/null || die "KMS plaintext is not valid base64"
    unset pt
    ;;
  *) die "unknown verb '${1:-}' (expected: resolve)" ;;
esac
