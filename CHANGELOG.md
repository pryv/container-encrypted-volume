# Changelog

## 0.1.0

Initial release — modular encryption-at-rest for containerised applications,
layered onto an application image at build time.

- **Backend seam** (`CEV_BACKEND`): `manifest.json` + 8-verb `backend.sh`
  contract. Ships **LUKS** (reference, block-level dm-crypt) and **gocryptfs**
  (FUSE-stacked) backends. A backend-conformance harness asserts idempotency,
  ciphertext-at-rest after close, data persistence across a close/open cycle, and
  honest capability reporting.
- **Key-provider seam** (`CEV_KEY_PROVIDER`): `manifest.json` + `provider.sh
  resolve` contract delivering 32 key bytes. Ships `env`, `file`, `exec` (wrap
  any cloud secret CLI), `clevis` (TPM2 / Tang / PKCS#11 / Shamir), and `aws-kms`
  (envelope — unwrap a KMS-wrapped data key via the container identity).
- Optional HKDF-SHA256 key derivation (`CEV_KEY_PURPOSE`) so one operator key can
  feed multiple independent uses.
- `entrypoint-wrapper.sh` brings the volume up, relocates the app's data roots
  into it, and exec's the original application entrypoint. Transparent
  pass-through when `CEV_ENABLED` is not `true`.
- Operations CLI: `up`, `down`, `status`, `rotate` (no bulk re-encrypt on LUKS),
  `header-backup`, `grow`.
- Templates (`backends/_template/`, `key-providers/_template/`) + authoring and
  operating guides so other backends/providers plug in without core changes.
- Distribution image published to `pryvio/container-encrypted-volume`;
  CI runs static checks + LUKS and gocryptfs conformance.
- Verified end-to-end on a real open-pryv.io overlay: a registered user's event
  is stored on the encrypted volume, persists across restart, and is ciphertext
  at rest.
