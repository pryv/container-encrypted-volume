#!/usr/bin/env bash
#
# conformance.sh <backend> — drive a backend through the full verb lifecycle and
# assert the contract invariants. Run on a host/container that grants the
# backend's manifest.requires (e.g. LUKS needs --privileged).
#
#   docker run --rm --privileged -v "$PWD:/cev" -w /cev <image-with-cryptsetup> \
#     test/conformance.sh luks
set -euo pipefail

BACKEND="${1:?usage: conformance.sh <backend>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
MARKER="CEV-PLAINTEXT-MARKER-$$-do-not-occur-in-ciphertext"

export CEV_BACKEND="$BACKEND"
export CEV_KEY_PROVIDER=env
export CEV_KEY="$(openssl rand -base64 32)"
export CEV_CONTAINER="$WORK/data.img"
export CEV_MOUNT="$WORK/mnt"
export CEV_SIZE_GIB="${CEV_SIZE_GIB:-1}"
export CEV_MAP_NAME="cev_conf_$$"
CEV="$ROOT/cev.sh"

pass=0; fail=0
check() { if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
cleanup() { "$CEV" down >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "== conformance: backend=$BACKEND =="

echo "[1] up — provision + open + mount"
"$CEV" up
check "mount point is mounted"        "mountpoint -q '$CEV_MOUNT'"
printf '%s\n' "$MARKER" > "$CEV_MOUNT/probe.txt"
check "can write to the volume"       "[ -f '$CEV_MOUNT/probe.txt' ]"

echo "[2] up again — idempotent"
"$CEV" up
check "still mounted after 2nd up"    "mountpoint -q '$CEV_MOUNT'"
check "data intact after 2nd up"      "grep -q '$MARKER' '$CEV_MOUNT/probe.txt'"

echo "[3] down — ciphertext at rest"
"$CEV" down
check "unmounted after down"          "! mountpoint -q '$CEV_MOUNT'"
# ciphertext-at-rest: the marker must not appear in the container (file or dir)
if [ -d "$CEV_CONTAINER" ]; then
  check "plaintext marker absent from cipher dir" "! grep -raq '$MARKER' '$CEV_CONTAINER'"
else
  check "plaintext marker absent from container file" "! grep -aq '$MARKER' '$CEV_CONTAINER'"
fi
if [ "$BACKEND" = luks ]; then
  check "container file is a LUKS volume" "cryptsetup isLuks '$CEV_CONTAINER'"
fi

echo "[4] down again — idempotent"
"$CEV" down
check "still unmounted after 2nd down" "! mountpoint -q '$CEV_MOUNT'"

echo "[5] reopen — data persists across close/open"
"$CEV" up
check "data persists across cycle"    "grep -q '$MARKER' '$CEV_MOUNT/probe.txt'"

echo "[6] header-backup (if supported)"
if grep -q '"separableHeaderBackup": true' "$ROOT/backends/$BACKEND/manifest.json"; then
  export CEV_HEADER_BACKUP="$WORK/hdr.bin"
  "$CEV" header-backup
  check "header backup file produced"  "[ -s '$CEV_HEADER_BACKUP' ]"
else
  echo "  SKIP: backend declares separableHeaderBackup=false"
fi

"$CEV" down >/dev/null 2>&1 || true
echo "== result: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
