# Authoring a backend or a key provider

Both seams follow the same shape: a directory containing a `manifest.json`
(validated against a JSON Schema in [`schemas/`](../schemas/)) and a single
executable script implementing a fixed verb interface. To add one, copy the
matching `_template/`, implement the verbs, and pass the conformance harness.

The key never appears on argv or in logs. `cev.sh` resolves it into a tmpfs
keyfile, optionally HKDF-derives it (`CEV_KEY_PURPOSE`), hands the file to the
backend, and shreds it.

---

## Backends — `backends/<name>/`

`manifest.json` (schema: [`backend.manifest.schema.json`](../schemas/backend.manifest.schema.json))
declares `requires` (runtime flags the backend needs) and honest `capabilities`
flags. A backend MUST report a capability as `false` rather than silently
degrade.

`backend.sh <verb>` implements eight verbs. Env provided by `cev.sh`:
`CEV_CONTAINER`, `CEV_MOUNT`, `CEV_KEYFILE`, `CEV_SIZE_GIB`, `CEV_MAP_NAME`,
`CEV_NEW_KEYFILE` (rotate), `CEV_HEADER_BACKUP` (header-backup).

| Verb | Must guarantee |
|---|---|
| `preflight` | exit non-zero + a human message if `requires` is not granted |
| `provision` | idempotent; create container if absent; never overwrite foreign data |
| `open` | idempotent; after success `$CEV_MOUNT` is mounted writable; format fs on first open only |
| `close` | idempotent; after success the container is ciphertext at rest |
| `status` | machine-readable; never mutates |
| `rotate` | swap key `$CEV_KEYFILE`→`$CEV_NEW_KEYFILE`; set `rotateWithoutReencrypt` honestly |
| `header-backup` | write recovery metadata to `$CEV_HEADER_BACKUP`, or no-op if `separableHeaderBackup=false` |
| `grow` | expand to `$CEV_SIZE_GIB` if `growInPlace`, else exit non-zero |

[`backends/luks/`](../backends/luks/) is the worked reference.

---

## Key providers — `key-providers/<name>/`

`manifest.json` (schema: [`key-provider.manifest.schema.json`](../schemas/key-provider.manifest.schema.json))
declares `envelope` (true if the key is stored wrapped and unwrapped by an
external KMS using the container identity) and the `CEV_*` `vars` it reads.

`provider.sh resolve` writes exactly **32 raw key bytes** to `$CEV_KEYFILE`.
That's the whole contract — `cev.sh` validates length and handles derivation.

Reference providers: `env`, `file`, `exec` (wrap any cloud CLI). For
hardware/network-bound unlock (TPM2 / Tang / PKCS#11 / threshold) write a thin
`clevis` provider that shells out to `clevis decrypt` rather than reimplementing
it. For envelope providers (`aws-kms`, `vault-transit`, …): read the wrapped
blob, call the KMS to unwrap via the container's identity, write the plaintext.

---

## Testing

```sh
test/validate-manifests.sh          # JSON well-formedness of every manifest
test/conformance.sh <backend>       # full verb lifecycle + invariants
```

The conformance run must execute where the backend's `requires` are granted
(LUKS → `--privileged`). It asserts idempotency, ciphertext-at-rest after
`close`, data persistence across a close/open cycle, and (where supported)
header backup.
