#!/usr/bin/env bash
#
# gocryptfs backend — second reference implementation of the backend contract,
# proving the seam is not LUKS-shaped. FUSE-stacked, per-file encryption.
#
# Here $CEV_CONTAINER is the CIPHER DIRECTORY (not a loopback file). gocryptfs
# stores the encrypted master key + parameters in $CEV_CONTAINER/gocryptfs.conf,
# so "header backup" = copy that file, and key rotation rewraps the master key
# (no bulk re-encrypt).
#
# The unlock key arrives as 32 raw bytes in $CEV_KEYFILE; gocryptfs takes a text
# passphrase, so we feed it the base64 of those bytes via a transient passfile.
set -euo pipefail

: "${CEV_CONTAINER:?}"; : "${CEV_MOUNT:?}"
CONF="$CEV_CONTAINER/gocryptfs.conf"

log() { printf 'gocryptfs: %s\n' "$*" >&2; }
die() { printf 'gocryptfs: ERROR: %s\n' "$*" >&2; exit 1; }

is_provisioned() { [ -f "$CONF" ]; }
is_mounted()     { mountpoint -q "$CEV_MOUNT" 2>/dev/null; }

# base64 of the raw keyfile -> a transient passfile (single line). Echoes its path.
passfile_from() { # <raw-keyfile>
  local src="$1" pf
  [ -s "$src" ] || die "key file $src is empty"
  pf="$(mktemp "${TMPDIR:-/tmp}/cev.gpass.XXXXXX")"; chmod 600 "$pf"
  base64 < "$src" | tr -d '\n' > "$pf"
  printf '%s' "$pf"
}
shred_file() { [ -n "${1:-}" ] && [ -f "$1" ] && { shred -u "$1" 2>/dev/null || rm -f "$1"; }; }

preflight() {
  command -v gocryptfs   >/dev/null 2>&1 || die "gocryptfs not found in image"
  command -v fusermount  >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1 || die "fusermount (fuse) not found"
  [ -e /dev/fuse ] || die "/dev/fuse missing — grant --device /dev/fuse"
  log "preflight ok (note: mounting also needs --cap-add SYS_ADMIN and --security-opt apparmor=unconfined)"
}

provision() {
  if is_provisioned; then log "already initialised: $CEV_CONTAINER"; return 0; fi
  mkdir -p "$CEV_CONTAINER"
  [ -z "$(ls -A "$CEV_CONTAINER" 2>/dev/null)" ] || die "$CEV_CONTAINER is not empty — refusing to init"
  local pf; pf="$(passfile_from "$CEV_KEYFILE")"; trap 'shred_file "$pf"' RETURN
  gocryptfs -init -q -passfile "$pf" "$CEV_CONTAINER" || die "gocryptfs -init failed"
  log "initialised"
}

open() {
  is_provisioned || die "not provisioned — run provision first"
  mkdir -p "$CEV_MOUNT"
  if is_mounted; then return 0; fi
  local pf; pf="$(passfile_from "$CEV_KEYFILE")"; trap 'shred_file "$pf"' RETURN
  gocryptfs -q -passfile "$pf" "$CEV_CONTAINER" "$CEV_MOUNT" || die "gocryptfs mount failed (need apparmor=unconfined?)"
  log "mounted at $CEV_MOUNT"
}

close() {
  if is_mounted; then
    fusermount -u "$CEV_MOUNT" 2>/dev/null || fusermount3 -u "$CEV_MOUNT" || die "fusermount -u failed"
    log "unmounted $CEV_MOUNT"
  fi
  return 0
}

status() {
  printf 'backend=gocryptfs cipherdir=%s\n' "$CEV_CONTAINER"
  printf 'provisioned=%s mounted=%s\n' \
    "$(is_provisioned && echo yes || echo no)" \
    "$(is_mounted && echo yes || echo no)"
}

rotate() {
  is_provisioned || die "not provisioned"
  [ -s "${CEV_NEW_KEYFILE:?new key required}" ] || die "new keyfile empty"
  local oldpf newpf; oldpf="$(passfile_from "$CEV_KEYFILE")"; newpf="$(passfile_from "$CEV_NEW_KEYFILE")"
  trap 'shred_file "$oldpf"; shred_file "$newpf"' RETURN
  # -passwd: -passfile supplies the OLD password; the NEW is read from stdin.
  gocryptfs -q -passwd -passfile "$oldpf" "$CEV_CONTAINER" < "$newpf" \
    || die "gocryptfs -passwd failed (wrong current key?)"
  log "rotated passphrase (master key rewrapped, no re-encrypt)"
}

header_backup() {
  is_provisioned || die "not provisioned"
  : "${CEV_HEADER_BACKUP:?set CEV_HEADER_BACKUP to the output path}"
  cp "$CONF" "$CEV_HEADER_BACKUP" || die "could not copy gocryptfs.conf"
  log "config (encrypted master key) backed up to $CEV_HEADER_BACKUP (store off-host)"
}

grow() {
  die "gocryptfs grows with the underlying filesystem; there is no fixed-size container to grow (growInPlace=false)"
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
