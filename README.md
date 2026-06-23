# container-encrypted-volume

Modular **encryption-at-rest for containerised applications**. It provisions and
mounts an encrypted volume *inside the container* on boot, so an application's
data directories sit on ciphertext at rest — with **two pluggable seams**:

- a **storage backend** (how the bytes are encrypted on disk) — LUKS today,
  gocryptfs as a second implementation, anything else via the contract;
- a **key provider** (where the unlock key comes from at boot) — `env`, `file`,
  `exec` (wrap any cloud CLI), `clevis` (TPM2 / Tang / PKCS#11 / threshold), or a
  cloud KMS envelope provider.

It is **layered onto an existing application image** — you do not fork the app.
The reference consumer is [open-pryv.io](https://github.com/pryv/open-pryv.io),
but nothing here is specific to it.

```
FROM your-app-image:tag
RUN apt-get update && apt-get install -y cryptsetup && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/pryv/container-encrypted-volume /cev /opt/cev
ENTRYPOINT ["/opt/cev/entrypoint-wrapper.sh"]
# CEV_* env selects backend + key provider and points app data roots at the mount
```

## What it protects (threat model)

Defends data on the **storage medium**: stolen / lost / decommissioned disks,
off-host volume backups, cloud snapshots. The container file is ciphertext
whenever it is not mounted.

It does **not** defend a *running* container — once mounted the volume is
plaintext to anyone with access to the live host. That is the job of access
control / authentication, and is exactly the scope encryption-at-rest
requirements (e.g. HIPAA §164.312(a)(2)(iv) + breach safe-harbor per NIST SP
800-111; GDPR Art.32(1)(a)) ask the at-rest control to cover. Per-tenant key
separation and "server never sees plaintext" are stronger, different models
(application-level field encryption / end-to-end) and out of scope here.

A useful property of LUKS: the key is needed only at `cryptsetup open`; afterwards
the master key lives in the kernel keyring, so the plaintext key is wiped from
userspace immediately. It exists in the container for one unlock call, not the
process lifetime.

## Runtime requirements

LUKS needs kernel `dm_crypt` + device-mapper, which in a container means
`--privileged` (or the granular `--cap-add SYS_ADMIN` + `--device
/dev/mapper/control --device /dev/loop-control`). Restricted Kubernetes Pod
Security profiles commonly forbid this — on such targets use host/operator-side
full-disk encryption instead. Each backend declares what it `requires` in its
manifest, and `preflight` fails fast with a precise message if it is missing.

## The two contracts

| Seam | Lives in | Selected by | Contract |
|---|---|---|---|
| Backend | `backends/<name>/` | `CEV_BACKEND` | `manifest.json` (+ schema) + `backend.sh` 8-verb interface |
| Key provider | `key-providers/<name>/` | `CEV_KEY_PROVIDER` | `manifest.json` (+ schema) + `provider.sh resolve` |

Adding a new backend or provider = copy the matching `_template/`, implement the
verbs, and pass the conformance harness. See
[docs/AUTHORING.md](docs/AUTHORING.md).

**Operators:** see [docs/OPERATING.md](docs/OPERATING.md) for the threat model,
run flags, key-provider choice (incl. cloud-KMS / IAM Roles Anywhere), rotation,
and disaster recovery.

## Configuration (CEV_* environment)

| Variable | Meaning | Default |
|---|---|---|
| `CEV_ENABLED` | master on/off | `false` |
| `CEV_BACKEND` | backend name | `luks` |
| `CEV_KEY_PROVIDER` | key provider name | `env` |
| `CEV_CONTAINER` | encrypted container file (or cipher dir) | `/var/lib/cev/data.img` |
| `CEV_MOUNT` | mount point for the decrypted filesystem | `/var/lib/cev/mnt` |
| `CEV_SIZE_GIB` | initial container size (sparse), provisioned once | `10` |
| `CEV_MAP_NAME` | device-mapper name (LUKS) | `cev_data` |
| `CEV_KEY_PURPOSE` | optional HKDF-SHA256 purpose label (one key → many uses) | *(unset = use key as-is)* |
| `CEV_EXPORTS` | space-separated `VAR=subpath` exported + created under the mount | *(none)* |
| `CEV_EXEC` | command to `exec` after the volume is up (the app entrypoint) | `"$@"` |

Provider-specific variables are documented in each `key-providers/<name>/`.

## Manual use (outside the entrypoint)

```sh
CEV_BACKEND=luks CEV_KEY_PROVIDER=env CEV_KEY="$(openssl rand -base64 32)" \
CEV_CONTAINER=/data/vol.img CEV_MOUNT=/data/mnt CEV_SIZE_GIB=5 \
  ./cev.sh up         # preflight + provision + open + mount
./cev.sh status
./cev.sh down         # unmount + close (ciphertext at rest again)
```

## Testing

`test/conformance.sh <backend>` drives a backend through the full verb lifecycle
on a throwaway container and asserts every invariant (idempotency,
ciphertext-at-rest after close, data persists across close/open, key never on
argv). It must run on a host/container that grants the backend's `requires`.
