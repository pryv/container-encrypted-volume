#!/usr/bin/env bash
#
# cev.sh — orchestrate an encrypted volume from a pluggable backend + key provider.
#
# Verbs:
#   up      preflight + provision + open + mount (idempotent; safe every boot)
#   down    unmount + close (ciphertext at rest again)
#   status  report backend state
#   rotate  swap the unlock key (needs CEV_NEW_* provider vars)
#   header-backup   emit recovery metadata to $CEV_HEADER_BACKUP
#   grow    expand the container to $CEV_SIZE_GIB
#
# The key is resolved into a tmpfs keyfile, optionally HKDF-derived with a purpose
# label, handed to the backend, then shredded. It is never passed on argv.
set -euo pipefail

CEV_HOME="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

: "${CEV_BACKEND:=luks}"
: "${CEV_KEY_PROVIDER:=env}"
: "${CEV_CONTAINER:=/var/lib/cev/data.img}"
: "${CEV_MOUNT:=/var/lib/cev/mnt}"
: "${CEV_SIZE_GIB:=10}"
: "${CEV_MAP_NAME:=cev_data}"
export CEV_CONTAINER CEV_MOUNT CEV_SIZE_GIB CEV_MAP_NAME

log()  { printf 'cev: %s\n' "$*" >&2; }
die()  { printf 'cev: ERROR: %s\n' "$*" >&2; exit 1; }

backend_sh()  { printf '%s/backends/%s/backend.sh' "$CEV_HOME" "$CEV_BACKEND"; }
provider_sh() { printf '%s/key-providers/%s/provider.sh' "$CEV_HOME" "$1"; }

# --- key handling ----------------------------------------------------------

# tmpfs location for the transient keyfile: prefer RAM-backed /dev/shm.
keyfile_mktemp() {
  local d
  for d in /dev/shm /run "${TMPDIR:-/tmp}"; do
    [ -d "$d" ] && [ -w "$d" ] && { mktemp "$d/cev.key.XXXXXX"; return; }
  done
  die "no writable tmpfs dir for the transient keyfile"
}

shred_file() { [ -n "${1:-}" ] && [ -f "$1" ] && { shred -u "$1" 2>/dev/null || rm -f "$1"; }; }

# resolve_key <provider-name> <out-keyfile>
# Runs the provider (which writes raw key bytes to $CEV_KEYFILE), optionally
# HKDF-derives, and validates a 32-byte result.
resolve_key() {
  local provider="$1" out="$2" psh
  psh="$(provider_sh "$provider")"
  [ -x "$psh" ] || die "unknown key provider '$provider' (expected $psh)"
  ( umask 077; : > "$out" )
  CEV_KEYFILE="$out" "$psh" resolve || die "key provider '$provider' failed to resolve a key"
  [ -n "${CEV_KEY_PURPOSE:-}" ] && derive_key "$out" "$CEV_KEY_PURPOSE"
  local n; n="$(wc -c < "$out" | tr -d ' ')"
  [ "$n" = "32" ] || die "resolved key must be 32 bytes, got $n (provider '$provider')"
}

# derive_key <keyfile> <purpose> — HKDF-SHA256(ikm=key, salt="", info=purpose) -> 32 bytes, in place.
derive_key() {
  local kf="$1" purpose="$2" tmp hexkey hexinfo
  command -v openssl >/dev/null 2>&1 || die "CEV_KEY_PURPOSE set but openssl is not available"
  hexkey="$(od -An -v -tx1 < "$kf" | tr -d ' \n')"
  hexinfo="$(printf '%s' "$purpose" | od -An -v -tx1 | tr -d ' \n')"
  tmp="$(keyfile_mktemp)"
  if ! openssl kdf -keylen 32 -binary \
        -kdfopt digest:SHA256 -kdfopt hexkey:"$hexkey" -kdfopt hexinfo:"$hexinfo" \
        HKDF > "$tmp" 2>/dev/null; then
    shred_file "$tmp"; die "HKDF derivation failed (needs OpenSSL 3 'kdf' command)"
  fi
  cat "$tmp" > "$kf"; shred_file "$tmp"
}

# --- verbs -----------------------------------------------------------------

cev_up() {
  local bsh kf; bsh="$(backend_sh)"
  [ -x "$bsh" ] || die "unknown backend '$CEV_BACKEND' (expected $bsh)"
  "$bsh" preflight || die "backend '$CEV_BACKEND' preflight failed"
  kf="$(keyfile_mktemp)"; trap 'shred_file "${kf:-}"' EXIT
  resolve_key "$CEV_KEY_PROVIDER" "$kf"
  CEV_KEYFILE="$kf" "$bsh" provision
  CEV_KEYFILE="$kf" "$bsh" open
  shred_file "$kf"; trap - EXIT
  log "volume up at $CEV_MOUNT (backend=$CEV_BACKEND provider=$CEV_KEY_PROVIDER)"
}

cev_down()   { "$(backend_sh)" close; log "volume down (ciphertext at rest)"; }
cev_status() { "$(backend_sh)" status; }

cev_rotate() {
  local bsh old new; bsh="$(backend_sh)"
  old="$(keyfile_mktemp)"; new="$(keyfile_mktemp)"
  trap 'shred_file "${old:-}"; shred_file "${new:-}"' EXIT
  resolve_key "$CEV_KEY_PROVIDER" "$old"
  resolve_key "${CEV_NEW_KEY_PROVIDER:-$CEV_KEY_PROVIDER}" "$new"
  CEV_KEYFILE="$old" CEV_NEW_KEYFILE="$new" "$bsh" rotate
  shred_file "$old"; shred_file "$new"; trap - EXIT
  log "unlock key rotated"
}

cev_header_backup() { "$(backend_sh)" header-backup; }
cev_grow()          { local kf; kf="$(keyfile_mktemp)"; trap 'shred_file "${kf:-}"' EXIT
                      resolve_key "$CEV_KEY_PROVIDER" "$kf"
                      CEV_KEYFILE="$kf" "$(backend_sh)" grow; shred_file "$kf"; trap - EXIT; }

case "${1:-}" in
  up)            cev_up ;;
  down)          cev_down ;;
  status)        cev_status ;;
  rotate)        cev_rotate ;;
  header-backup) cev_header_backup ;;
  grow)          cev_grow ;;
  *) die "usage: cev.sh {up|down|status|rotate|header-backup|grow}" ;;
esac
