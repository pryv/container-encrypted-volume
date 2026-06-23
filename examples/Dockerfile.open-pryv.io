# Example: layer encryption-at-rest onto the stock open-pryv.io image.
# Builds pryvio/open-pryv.io-encrypted:${BASE_TAG} — the base image is unchanged.
#
#   docker build -f examples/Dockerfile.open-pryv.io \
#     --build-arg BASE_TAG=latest -t pryvio/open-pryv.io-encrypted:latest .
#
# Run (LUKS needs --privileged); key from AWS KMS via the exec provider here:
#   docker run --privileged \
#     -e CEV_ENABLED=true \
#     -e CEV_KEY_PROVIDER=exec \
#     -e CEV_KEY_COMMAND="aws kms decrypt --region eu-central-2 \
#          --ciphertext-blob fileb:///run/secrets/cev.blob \
#          --query Plaintext --output text" \
#     -v pryv-encrypted:/app/var-pryv/encrypted \
#     pryvio/open-pryv.io-encrypted:latest

ARG BASE_TAG=latest
FROM pryvio/open-pryv.io:${BASE_TAG}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends cryptsetup e2fsprogs openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=pryvio/container-encrypted-volume:latest /cev /opt/cev

# Defaults: feature OFF, so this image behaves exactly like the base until an
# operator sets CEV_ENABLED=true. Encryption config lives entirely here (CEV_*),
# never in open-pryv.io's own config.
ENV CEV_ENABLED=false \
    CEV_BACKEND=luks \
    CEV_KEY_PROVIDER=env \
    CEV_CONTAINER=/app/var-pryv/encrypted/data.img \
    CEV_MOUNT=/app/var-pryv/encrypted/mnt \
    CEV_SIZE_GIB=50 \
    CEV_EXPORTS="PRYV_DATADIR=data" \
    CEV_EXEC=/app/scripts/docker-entrypoint.sh

# IMPORTANT — relocate ALL data roots into $CEV_MOUNT, not only attachments.
# All three are open-pryv.io config keys and support ${ENV} interpolation, so NO
# base-image change is needed — set them in your override-config.yml:
#   * Attachments: handled here by CEV_EXPORTS (PRYV_DATADIR -> $CEV_MOUNT/data),
#     which the stock production config already reads
#     (storages:engines:...:attachmentsDirPath: "${PRYV_DATADIR}/...").
#   * SQLite per-user base:  storages:engines:sqlite:path:  "${PRYV_DATADIR}/sqlite"
#   * rqlite data dir:       storages:engines:rqlite:dataDir: "${PRYV_DATADIR}/rqlite-data"
#     Do NOT reuse /app/var-pryv/rqlite-data: the base image declares it as a
#     VOLUME, which would shadow the encrypted mount with an anonymous volume.
#   * PostgreSQL (when used) is an external, operator-managed data dir outside
#     this container — encrypt it operator-side; this overlay does not cover it.

ENTRYPOINT ["/opt/cev/entrypoint-wrapper.sh"]
CMD []
