#!/usr/bin/env bash
#
# LUKS backend — reference implementation of the backend contract.
#
# Verb interface (see ../../docs/AUTHORING.md):
#   preflight provision open close status rotate header-backup grow
#
# Env contract (set by cev.sh):
#   CEV_CONTAINER  loopback container file path
#   CEV_MOUNT      mount point for the decrypted filesystem
#   CEV_KEYFILE    file holding the raw 32-byte unlock key (tmpfs; never argv)
#   CEV_SIZE_GIB   initial container size (provision)
#   CEV_MAP_NAME   device-mapper name
#   CEV_NEW_KEYFILE  new key (rotate)
#   CEV_HEADER_BACKUP  output path (header-backup)
set -euo pipefail

: "${CEV_CONTAINER:?}"; : "${CEV_MOUNT:?}"; : "${CEV_MAP_NAME:?}"
MAPDEV="/dev/mapper/${CEV_MAP_NAME}"

log() { printf 'luks: %s\n' "$*" >&2; }
die() { printf 'luks: ERROR: %s\n' "$*" >&2; exit 1; }

is_provisioned() { [ -f "$CEV_CONTAINER" ] && cryptsetup isLuks "$CEV_CONTAINER" 2>/dev/null; }
# consult the kernel device-mapper table, not just the /dev node: under
# --privileged a mapping lives in the host kernel and may exist even when this
# container's /dev/mapper node is absent (or vice-versa).
is_open()        { cryptsetup status "$CEV_MAP_NAME" >/dev/null 2>&1; }
is_mounted()     { mountpoint -q "$CEV_MOUNT" 2>/dev/null; }
need_key()       { [ -s "${CEV_KEYFILE:?key required}" ] || die "keyfile $CEV_KEYFILE is empty"; }

preflight() {
  command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup not found in image"
  command -v mkfs.ext4  >/dev/null 2>&1 || die "mkfs.ext4 (e2fsprogs) not found in image"
  [ -e /dev/mapper/control ] || die "device-mapper unavailable — grant --privileged (or --device /dev/mapper/control) and ensure host has dm_crypt"
  log "preflight ok"
}

provision() {
  if is_provisioned; then log "already provisioned: $CEV_CONTAINER"; return 0; fi
  [ -e "$CEV_CONTAINER" ] && die "$CEV_CONTAINER exists but is not a LUKS container — refusing to overwrite"
  need_key
  mkdir -p "$(dirname "$CEV_CONTAINER")"
  log "creating ${CEV_SIZE_GIB}GiB sparse container $CEV_CONTAINER"
  truncate -s "${CEV_SIZE_GIB}G" "$CEV_CONTAINER"
  cryptsetup luksFormat --type luks2 --batch-mode --key-file "$CEV_KEYFILE" "$CEV_CONTAINER" \
    || die "luksFormat failed"
  log "provisioned"
}

open() {
  is_provisioned || die "not provisioned — run provision first"
  # If a mapping with our name already exists but is NOT mounted in this
  # container, it is stale — typically leaked into the host kernel by a previous
  # --privileged container. Close it and re-open so the supplied key is ALWAYS
  # validated (never silently reuse a mapping a wrong key could ride on). If it
  # IS mounted here, this is just an idempotent repeat — keep it.
  if is_open && ! is_mounted; then
    log "stale mapping $CEV_MAP_NAME present (no mount here) — closing to re-validate key"
    cryptsetup close "$CEV_MAP_NAME" 2>/dev/null || die "could not clear stale mapping $CEV_MAP_NAME"
  fi
  if ! is_open; then
    need_key
    cryptsetup open --key-file "$CEV_KEYFILE" "$CEV_CONTAINER" "$CEV_MAP_NAME" \
      || die "cryptsetup open failed (wrong key?)"
    log "opened $MAPDEV"
  fi
  [ -b "$MAPDEV" ] || die "mapping active but $MAPDEV node missing in this container"
  # first open after provision: the mapped device has no filesystem yet
  if ! blkid "$MAPDEV" >/dev/null 2>&1; then
    log "formatting ext4 on first open"
    mkfs.ext4 -q "$MAPDEV" || die "mkfs.ext4 failed"
  fi
  mkdir -p "$CEV_MOUNT"
  if ! is_mounted; then
    mount "$MAPDEV" "$CEV_MOUNT" || die "mount failed"
    log "mounted at $CEV_MOUNT"
  fi
}

close() {
  is_mounted && { umount "$CEV_MOUNT" || die "umount failed"; log "unmounted $CEV_MOUNT"; }
  is_open    && { cryptsetup close "$CEV_MAP_NAME" || die "cryptsetup close failed"; log "closed $MAPDEV"; }
  return 0
}

status() {
  printf 'backend=luks container=%s\n' "$CEV_CONTAINER"
  printf 'provisioned=%s open=%s mounted=%s\n' \
    "$(is_provisioned && echo yes || echo no)" \
    "$(is_open && echo yes || echo no)" \
    "$(is_mounted && echo yes || echo no)"
}

rotate() {
  is_provisioned || die "not provisioned"
  need_key
  [ -s "${CEV_NEW_KEYFILE:?new key required}" ] || die "new keyfile empty"
  # LUKS key-slots: add the new key, then remove the old. No bulk re-encrypt.
  cryptsetup luksAddKey --key-file "$CEV_KEYFILE" "$CEV_CONTAINER" "$CEV_NEW_KEYFILE" \
    || die "luksAddKey failed (wrong current key?)"
  cryptsetup luksRemoveKey --key-file "$CEV_KEYFILE" "$CEV_CONTAINER" \
    || die "luksRemoveKey (old) failed"
  log "rotated unlock key (slot swap, no re-encrypt)"
}

header_backup() {
  is_provisioned || die "not provisioned"
  : "${CEV_HEADER_BACKUP:?set CEV_HEADER_BACKUP to the output path}"
  cryptsetup luksHeaderBackup "$CEV_CONTAINER" --header-backup-file "$CEV_HEADER_BACKUP" \
    || die "luksHeaderBackup failed"
  log "header backed up to $CEV_HEADER_BACKUP (store off-host; a lost header bricks the volume)"
}

grow() {
  is_open || die "open the volume before grow"
  need_key
  log "growing container to ${CEV_SIZE_GIB}GiB"
  truncate -s "${CEV_SIZE_GIB}G" "$CEV_CONTAINER"
  cryptsetup resize --key-file "$CEV_KEYFILE" "$CEV_MAP_NAME" || die "cryptsetup resize failed"
  resize2fs "$MAPDEV" || die "resize2fs failed"
  log "grown"
}

case "${1:-}" in
  preflight)     preflight ;;
  provision)     provision ;;
  open)          open ;;
  close)         close ;;
  status)        status ;;
  rotate)        rotate ;;
  header-backup) header_backup ;;
  grow)          grow ;;
  *) die "unknown verb '${1:-}'" ;;
esac
