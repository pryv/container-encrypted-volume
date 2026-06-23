# Operating an encrypted volume

This guide is for operators turning on encryption-at-rest for a containerised
application by layering `container-encrypted-volume` onto its image.

## 1. What it protects (and what it does not)

**Protects** data on the storage medium: stolen / lost / decommissioned disks,
off-host volume backups, cloud snapshots. With the LUKS backend the container
file is ciphertext on disk **at all times** — unlocking creates an in-kernel
device mapping, it never rewrites the file — so the at-rest guarantee holds even
after an unclean stop or power loss.

**Does not protect** a *running* container: once the volume is mounted it is
plaintext to anyone with access to the live host. That is the job of access
control / authentication, and it is the scope encryption-at-rest controls are
expected to cover:

- **HIPAA** §164.312(a)(2)(iv) "Encryption and decryption" (addressable) — volume
  encryption satisfies it; and the **breach-notification safe harbor** (HHS
  guidance → NIST SP 800-111) explicitly recognises full-volume encryption, so an
  encrypted lost/stolen disk is not a reportable breach.
- **GDPR** Art.32(1)(a) lists encryption as an example technical measure;
  Art.34(3)(a) gives parallel relief when lost data was encrypted.

Per-tenant key separation and "server never sees plaintext" are stronger,
**different** models (application-level field encryption / end-to-end) and are
out of scope here.

## 2. Runtime requirements

| Backend | Required `docker run` flags | Notes |
|---|---|---|
| `luks` | `--privileged` (or `--cap-add SYS_ADMIN --device /dev/mapper/control --device /dev/loop-control`) | Needs the host kernel `dm_crypt` module. Near-native speed with AES-NI. |
| `gocryptfs` | `--cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined` | Reduced privilege, but the apparmor relaxation is mandatory or the FUSE mount is denied. |

Restricted Kubernetes Pod Security profiles commonly forbid both. On such
targets, use host/operator-side full-disk encryption instead. Each backend
declares its needs in `manifest.json`; `preflight` fails fast with a precise
message if they are missing.

## 3. Layer it onto your image

```dockerfile
ARG BASE_TAG=latest
FROM your-app:${BASE_TAG}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      cryptsetup e2fsprogs openssl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=pryvio/container-encrypted-volume:latest /cev /opt/cev
ENV CEV_ENABLED=false \
    CEV_BACKEND=luks \
    CEV_KEY_PROVIDER=env \
    CEV_CONTAINER=/var/lib/app/encrypted/data.img \
    CEV_MOUNT=/var/lib/app/encrypted/mnt \
    CEV_SIZE_GIB=50 \
    CEV_EXPORTS="APP_DATADIR=data" \
    CEV_EXEC=/path/to/your/original/entrypoint
ENTRYPOINT ["/opt/cev/entrypoint-wrapper.sh"]
```

With `CEV_ENABLED=false` (the default) the image behaves exactly like the base —
encryption is opt-in. See `examples/Dockerfile.open-pryv.io` for a worked
open-pryv.io overlay.

## 4. Choosing a key provider

The key source is pluggable (`CEV_KEY_PROVIDER`). All providers deliver the same
32-byte key; only *where it comes from* differs.

| Provider | Use when | Standing secret? |
|---|---|---|
| `env` | dev / simple; key in `CEV_KEY` (base64) | yes (the key itself) |
| `file` | key injected as a file (Docker/K8s secret, CSI driver) | yes |
| `exec` | wrap any cloud secret CLI (`aws secretsmanager …`, `gcloud secrets …`, `vault kv get …`) | depends on the CLI's auth |
| `clevis` | hardware/network-bound: TPM2, Tang, PKCS#11, Shamir threshold | no (bound to device/server) |
| `aws-kms` | **envelope**: store the key wrapped, unwrap at boot via AWS KMS | no (identity-based) |

**Prefer an envelope/identity provider** (`aws-kms`, or `clevis` with TPM2/Tang)
so there is no copyable plaintext key stored beside the data. The key is needed
only at the moment of unlock; with LUKS the master key then lives in the kernel
keyring and the plaintext key is wiped from userspace immediately.

### AWS-KMS from a non-AWS host (e.g. Exoscale)

The envelope "no copyable secret" benefit relies on the container's **identity**.
On AWS that is the instance/task IAM role. On a non-AWS host, use **AWS IAM Roles
Anywhere** (X.509-certificate-based temporary credentials) to keep the
identity-based posture without a long-lived access key. A tightly-scoped,
rotatable long-lived key is the simpler fallback — weaker, but it only authorises
a KMS unwrap and every use is logged in CloudTrail.

Residency: only the key-*unwrap* call reaches AWS — KMS never sees your data,
which stays ciphertext on your host. Pick a KMS key in a region matching your
residency needs (e.g. `eu-central-2`, Zurich). If you need zero foreign
dependency in the boot path, run `vault-transit` (self-hosted) via a `clevis`/
`exec` provider instead.

Create a wrapped data key once:

```sh
head -c 32 /dev/urandom > rawkey
aws kms encrypt --key-id alias/cev --region eu-central-2 \
  --plaintext fileb://rawkey --query CiphertextBlob --output text | base64 -d > cev.blob
shred -u rawkey      # ship cev.blob with the data; set CEV_KEY_PROVIDER=aws-kms CEV_KMS_BLOB=/…/cev.blob
```

## 5. Key rotation

```sh
# resolve the current key via the configured provider, add a new slot, drop the old
CEV_NEW_KEY_PROVIDER=env CEV_NEW_KEY="$(openssl rand -base64 32)" ./cev.sh rotate
```

With LUKS this rewraps the unlock key in a key-slot — **no bulk re-encryption** of
data. (`gocryptfs` likewise rewraps the master key.) Backends declare
`capabilities.rotateWithoutReencrypt` honestly in their manifest.

## 6. Disaster recovery — read this before enabling

**Key lost = data lost.** There is no backdoor. Two mandatory operator duties:

1. **Escrow the key** out-of-band (a secrets manager / KMS / vault), separate
   from the data.
2. **Back up the LUKS header** — a corrupted header bricks an otherwise-intact
   volume:
   ```sh
   CEV_HEADER_BACKUP=/safe/offhost/luks-header.bin ./cev.sh header-backup
   ```
   Store it off-host. (`gocryptfs` equivalent: back up `gocryptfs.conf`.)

## 7. Operations

```sh
./cev.sh status          # provisioned / open / mounted
./cev.sh up              # preflight + provision + open + mount (idempotent)
./cev.sh down            # unmount + close
CEV_SIZE_GIB=100 ./cev.sh grow   # expand (LUKS)
```

## 8. Coverage notes

- Everything written under `CEV_MOUNT` is covered. Point all of your app's data
  roots there.
- **External databases** (e.g. a PostgreSQL server in a separate container) write
  to *their own* data dir, outside this mount — encrypt those operator-side.
- **Remote object storage** (e.g. S3) is not under this mount — use the bucket's
  own server-side encryption.
- If your base image declares a `VOLUME` at a path you intend to relocate into the
  encrypted mount, point the data dir at a path **inside** `CEV_MOUNT` instead —
  an anonymous volume at the declared path would otherwise shadow the mount.
