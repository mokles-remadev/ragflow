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
#   WEB_PORT=8080                     web UI port when 80 is taken (HTTPS moves to WEB_PORT+363, e.g. 8443)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root/docker"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
# Prefer the Compose v2 plugin; fall back to a standalone docker-compose binary if it is v2+.
if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
elif command -v docker-compose >/dev/null && docker-compose version --short 2>/dev/null | grep -qE '^v?[2-9]'; then
  compose=(docker-compose)
else
  cat >&2 <<'MSG'
Docker Compose v2 is required (neither `docker compose` nor a v2 `docker-compose` was found).
Install it, then re-run this script:
  Debian/Ubuntu with Docker's apt repo:  sudo apt-get install -y docker-compose-plugin
  Any Linux:  mkdir -p ~/.docker/cli-plugins && \
    curl -fSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
      -o ~/.docker/cli-plugins/docker-compose && chmod +x ~/.docker/cli-plugins/docker-compose
MSG
  exit 1
fi

# Host ports: shell values override docker/.env for Compose interpolation.
env_port() { local v; v="$(grep -E "^$1=" .env | head -1 | cut -d= -f2)"; echo "${!1:-$v}"; }
if [[ -n "${WEB_PORT:-}" ]]; then
  export SVR_WEB_HTTP_PORT="$WEB_PORT" SVR_WEB_HTTPS_PORT="$((WEB_PORT + 363))"
fi
web_port="$(env_port SVR_WEB_HTTP_PORT)"
api_port="$(env_port SVR_HTTP_PORT)"

# Fail early with a clear message instead of a half-started stack.
# Skipped when the RAGFlow container already runs, since it then owns these ports itself.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
if [[ -z "$("${compose[@]}" -f docker-compose.yml ps -q ragflow-cpu ragflow-gpu 2>/dev/null || true)" ]]; then
  busy=()
  for var in SVR_WEB_HTTP_PORT SVR_WEB_HTTPS_PORT SVR_HTTP_PORT ADMIN_SVR_HTTP_PORT; do
    p="$(env_port "$var")"
    if [[ -n "$p" ]] && port_busy "$p"; then busy+=("$p ($var)"); fi
  done
  if (( ${#busy[@]} > 0 )); then
    echo "These host ports are already in use: ${busy[*]}" >&2
    echo "Find the owner with: sudo ss -ltnp 'sport = :<port>'  (or: sudo lsof -i :<port>)" >&2
    echo "Or move RAGFlow's web UI, e.g.: WEB_PORT=8080 $0" >&2
    exit 1
  fi
fi

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

"${compose[@]}" -f docker-compose.yml up -d

port="${api_port:-9380}"
echo "Waiting for the RAGFlow API on http://localhost:${port} …"
for _ in $(seq 1 120); do
  if curl -fsS -o /dev/null "http://localhost:${port}/api/v1/system/ping" 2>/dev/null; then
    echo "RAGFlow is up: open http://localhost$([[ "$web_port" == 80 ]] || echo ":$web_port")"
    echo "Next: sign up, set an embedding model (Model providers), create an API key (avatar → API), then run ingest.sh."
    exit 0
  fi
  sleep 5
done
echo "RAGFlow did not become healthy within 10 minutes. Check: ${compose[*]} -f docker/docker-compose.yml logs -f ragflow-cpu" >&2
exit 1
