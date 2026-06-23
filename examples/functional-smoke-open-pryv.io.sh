#!/usr/bin/env bash
#
# Functional smoke: boot open-pryv.io on a LUKS-encrypted volume produced by this
# project, store a real event, restart, and confirm the data persists AND is
# ciphertext at rest. Requires Docker with --privileged on the host.
#
#   bash examples/functional-smoke-open-pryv.io.sh
#
# Uses SQLite base storage so the events land on the encrypted mount (PostgreSQL
# would be an external, separately-encrypted data dir). Builds the overlay from
# this checkout via COPY (no registry needed).
set -uo pipefail
BASE="${BASE:-pryvio/open-pryv.io:latest}"
IMG=open-pryv-encrypted:smoke
NAME=cev-smoke
ENC=/tmp/cev-enc-smoke
CFG=/tmp/cev-override.yml
PORT=3010
URL="http://127.0.0.1:$PORT"
KEY=$(openssl rand -base64 32)
PHI="encrypted-event-content-$RANDOM"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cleanup(){ docker rm -f "$NAME" >/dev/null 2>&1; cryptsetup close cev_data 2>/dev/null; }
trap cleanup EXIT
cleanup; rm -rf "$ENC"; mkdir -p "$ENC"

cat > "$ROOT/Dockerfile.smoke" <<DOCKER
FROM $BASE
USER root
RUN apt-get update -qq && apt-get install -y -qq cryptsetup e2fsprogs openssl >/dev/null 2>&1
COPY . /opt/cev
RUN chmod +x /opt/cev/cev.sh /opt/cev/entrypoint-wrapper.sh /opt/cev/backends/*/backend.sh /opt/cev/key-providers/*/provider.sh
ENV CEV_ENABLED=true CEV_BACKEND=luks CEV_KEY_PROVIDER=env \\
    CEV_CONTAINER=/app/var-pryv/encrypted/data.img \\
    CEV_MOUNT=/app/var-pryv/encrypted/mnt CEV_SIZE_GIB=1 \\
    CEV_EXEC=/app/scripts/docker-entrypoint.sh
ENTRYPOINT ["/opt/cev/entrypoint-wrapper.sh"]
DOCKER
echo "== build overlay (FROM $BASE) =="
docker build -q -f "$ROOT/Dockerfile.smoke" -t "$IMG" "$ROOT" >/dev/null && echo built
rm -f "$ROOT/Dockerfile.smoke"

ADMIN=$(openssl rand -hex 16); FILES=$(openssl rand -hex 16)
cat > "$CFG" <<YAML
auth: { adminAccessKey: $ADMIN, filesReadTokenSecret: $FILES, trustedApps: '*@*' }
cluster: { apiWorkers: 1, hfsWorkers: 0, previewsWorker: false }
dnsLess: { isActive: true, publicUrl: $URL }
http: { ip: 0.0.0.0, port: 3000 }
service: { name: 'encrypted smoke', serial: '1', eventTypes: https://pryv.github.io/event-types/flat.json, home: $URL, support: $URL, terms: $URL }
services: { email: { enabled: { welcome: false, resetPassword: false } } }
logs: { console: { active: true, level: warn }, file: { active: false } }
storages:
  base: { engine: sqlite }
  series: { engine: sqlite }
  audit: { engine: sqlite }
  engines:
    sqlite: { path: /app/var-pryv/encrypted/mnt/users }
    filesystem: { attachmentsDirPath: /app/var-pryv/encrypted/mnt/attachments, previewsDirPath: /app/var-pryv/encrypted/mnt/previews }
    rqlite: { url: 'http://127.0.0.1:4001', raftPort: 4002, dataDir: /app/var-pryv/encrypted/mnt/rqlite-data }
YAML

run(){ docker run -d --name "$NAME" --privileged -e CEV_KEY="$KEY" -e NODE_ENV=production \
  -v "$ENC":/app/var-pryv/encrypted -v "$CFG":/app/config/override-config.yml:ro \
  -p "$PORT":3000 "$IMG" >/dev/null; }
wait_ready(){ for i in $(seq 1 60); do curl -fsS "$URL/reg/service/info" >/dev/null 2>&1 && return 0; sleep 1; done; docker logs --tail 30 "$NAME"; return 1; }
login(){ curl -fsS -X POST "$URL/smoketester/auth/login" -H 'Content-Type: application/json' -H 'Origin: https://smoke' \
  -d '{"username":"smoketester","password":"smokepass123","appId":"cev-smoke"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'; }

echo "== boot 1 =="; run; wait_ready || exit 1
curl -fsS -X POST "$URL/users" -H 'Content-Type: application/json' \
  -d '{"username":"smoketester","password":"smokepass123","email":"smoke@example.com","appId":"cev-smoke"}' >/dev/null && echo "user registered"
T=$(login)
curl -fsS -X POST "$URL/smoketester/streams" -H "Authorization: $T" -H 'Content-Type: application/json' -d '{"id":"diary","name":"Diary"}' >/dev/null
curl -sS -X POST "$URL/smoketester/events" -H "Authorization: $T" -H 'Content-Type: application/json' \
  -d "{\"streamIds\":[\"diary\"],\"type\":\"note/txt\",\"content\":\"$PHI\"}" >/dev/null && echo "event written"
curl -fsS "$URL/smoketester/events" -H "Authorization: $T" | grep -q "$PHI" && echo "  READBACK_OK" || { echo "  READBACK_FAIL"; exit 1; }

echo "== restart =="; docker rm -f "$NAME" >/dev/null; cryptsetup close cev_data 2>/dev/null
run; wait_ready || exit 1
curl -fsS "$URL/smoketester/events" -H "Authorization: $(login)" | grep -q "$PHI" && echo "  PERSIST_AFTER_RESTART_OK" || { echo "  PERSIST_FAIL"; exit 1; }

echo "== at-rest (container stopped) =="; docker rm -f "$NAME" >/dev/null; cryptsetup close cev_data 2>/dev/null
cryptsetup isLuks "$ENC/data.img" && echo "  CONTAINER_IS_LUKS"
grep -aq "$PHI" "$ENC/data.img" && { echo "  PLAINTEXT_LEAK!"; exit 1; } || echo "  EVENT_PLAINTEXT_ABSENT_OK"
echo "== functional smoke passed =="
