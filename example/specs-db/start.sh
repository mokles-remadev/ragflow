#!/usr/bin/env bash
# Start a local RAGFlow stack for the specification database.
#
# Usage:
#   example/specs-db/start.sh            # RAGFlow + deps, embedding model configured in the UI
#   WITH_TEI=1 example/specs-db/start.sh # also run a local embedding server (no cloud keys needed)
#
# Optional:
#   TEI_MODEL=BAAI/bge-small-en-v1.5  (default here; ~1.2 GB RAM, English)
#   TEI_MODEL=BAAI/bge-m3             (multilingual, ~21 GB RAM)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root/docker"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null || { echo "docker compose v2 is required" >&2; exit 1; }

# Elasticsearch (the default document engine) needs a higher mmap count on Linux.
if [[ "$(uname -s)" == "Linux" ]]; then
  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if (( current < 262144 )); then
    echo "Raising vm.max_map_count to 262144 (sudo)…"
    sudo sysctl -w vm.max_map_count=262144
  fi
fi

if [[ "${WITH_TEI:-0}" == "1" ]]; then
  # Mirror docker/.env's COMPOSE_PROFILES and add the local embedding server.
  doc_engine="${DOC_ENGINE:-elasticsearch}"
  device="${DEVICE:-cpu}"
  export TEI_MODEL="${TEI_MODEL:-BAAI/bge-small-en-v1.5}"
  export COMPOSE_PROFILES="${doc_engine},${device},metadata-${METADATA_DB_PROFILE:-mysql},tei-${device}"
  echo "Profiles: $COMPOSE_PROFILES  (TEI_MODEL=$TEI_MODEL)"
fi

docker compose -f docker-compose.yml up -d

port="$(grep -E '^SVR_HTTP_PORT=' .env | cut -d= -f2)"
port="${port:-9380}"
echo "Waiting for the RAGFlow API on http://localhost:${port} …"
for _ in $(seq 1 120); do
  if curl -fsS -o /dev/null "http://localhost:${port}/api/v1/system/ping" 2>/dev/null; then
    echo "RAGFlow is up: open http://localhost"
    echo "Next: sign up, set an embedding model (Model providers), create an API key (avatar → API), then run ingest.sh."
    exit 0
  fi
  sleep 5
done
echo "RAGFlow did not become healthy within 10 minutes. Check: docker compose -f docker/docker-compose.yml logs -f ragflow-cpu" >&2
exit 1
