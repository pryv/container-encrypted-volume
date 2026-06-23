# Distribution image: carries the /cev payload so application images can
#   COPY --from=pryvio/container-encrypted-volume:<tag> /cev /opt/cev
# This image is not meant to run on its own.
FROM alpine:3.20
WORKDIR /cev
COPY cev.sh entrypoint-wrapper.sh ./
COPY backends/ backends/
COPY key-providers/ key-providers/
COPY schemas/ schemas/
COPY docs/ docs/
RUN chmod +x cev.sh entrypoint-wrapper.sh \
      backends/*/backend.sh key-providers/*/provider.sh
LABEL org.opencontainers.image.source="https://github.com/pryv/container-encrypted-volume" \
      org.opencontainers.image.description="Pluggable encryption-at-rest payload for layering onto application images" \
      org.opencontainers.image.licenses="BSD-3-Clause"
