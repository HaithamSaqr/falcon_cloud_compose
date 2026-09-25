#!/usr/bin/env bash
# Falcon ERP — per-customer Docker Compose installer.
#
# One command spins up an isolated stack (API + Angular web) for a customer.
# Everything is derived from the customer NAME: container names, network,
# subdomains, and the data directory. All stateful data lives in host
# bind-mounts under /opt/<name>/, so image upgrades (manual OR via watchtower)
# recreate the containers but NEVER touch the data.
#
# Usage:
#   ./run.sh install --name eskan --api-port 5001 --web-port 5021 [--domain falcon-v.com]
#   ./run.sh upgrade --name eskan          # pull latest image + recreate, keeps data
#   ./run.sh down    --name eskan          # stop stack, KEEPS data
#   ./run.sh logs    --name eskan          # tail logs
#   ./run.sh list                          # show installed customers
#   ./run.sh watchtower                    # one shared auto-updater for the whole host
#
# Remote install straight from GitHub (one line):
#   curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/falcon_cloud_compose/main/run.sh \
#     | bash -s -- install --name eskan --api-port 5001 --web-port 5021

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
DOMAIN_DEFAULT="falcon-v.com"
BASE_DIR="${FALCON_BASE_DIR:-/opt}"   # each customer → /opt/<name>/
API_IMAGE="haithamsakr/falconerpapi:latest"
WEB_IMAGE="haithamsakr/falconerpangular:latest"
WATCHTOWER_TOKEN="falcon-update-token-2024"
WATCHTOWER_PORT="8088"

# ---- helpers ----------------------------------------------------------------
die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "➜ $*"; }
ok()   { echo "✅ $*"; }

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@";
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@";
  else die "docker compose not found. Install Docker first."; fi
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---- arg parsing ------------------------------------------------------------
ACTION="${1:-}"; [[ -n "$ACTION" && "$ACTION" != --* ]] && shift || ACTION="install"

NAME="" API_PORT="" WEB_PORT="" DOMAIN="$DOMAIN_DEFAULT" NO_WATCHTOWER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="${2:-}"; shift 2 ;;
    --api-port)     API_PORT="${2:-}"; shift 2 ;;
    --web-port)     WEB_PORT="${2:-}"; shift 2 ;;
    --domain)       DOMAIN="${2:-}"; shift 2 ;;
    --no-watchtower) NO_WATCHTOWER=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              die "Unknown option: $1" ;;
  esac
done

# Interactive fallback (only when a terminal is attached, e.g. git-clone flow).
prompt() { local v; read -r -p "$1: " v </dev/tty; echo "$v"; }
need_name() {
  [[ -n "$NAME" ]] || { [[ -t 0 ]] && NAME="$(prompt 'Customer name (lowercase, e.g. eskan)')"; }
  [[ -n "$NAME" ]] || die "Missing --name"
  [[ "$NAME" =~ ^[a-z][a-z0-9]*$ ]] || die "Name must be lowercase letters/digits, start with a letter."
}

customer_dir() { echo "$BASE_DIR/$NAME"; }

# ---- stack file generation --------------------------------------------------
write_stack() {
  local dir; dir="$(customer_dir)"
  mkdir -p "$dir/etc" "$dir/uploads" "$dir/app-data" \
    || die "Cannot create $dir (try: sudo $0 ...)."
  touch "$dir/.falcon"   # marker so `list` finds our stacks among other /opt dirs

  # .env — shell vars expand here (unquoted heredoc).
  cat > "$dir/.env" <<ENV
CUSTOMER=$NAME
DOMAIN=$DOMAIN
API_PORT=$API_PORT
WEB_PORT=$WEB_PORT
API_IMAGE=$API_IMAGE
WEB_IMAGE=$WEB_IMAGE
WATCHTOWER_URL=http://host.docker.internal:$WATCHTOWER_PORT
WATCHTOWER_TOKEN=$WATCHTOWER_TOKEN
ENV

  # docker-compose.yml — QUOTED heredoc so ${VAR} stays literal and is
  # interpolated by docker compose at runtime from .env above.
  cat > "$dir/docker-compose.yml" <<'YAML'
services:
  api:
    image: ${API_IMAGE}
    container_name: ${CUSTOMER}api
    ports:
      - "${API_PORT}:5001"
    environment:
      # Multi-tenant: TenantResolutionMiddleware resolves the per-request
      # connection from /app/App_Data/servers.xml (persisted in ./app-data).
      AppVersion__WatchtowerUrl: "${WATCHTOWER_URL}"
      AppVersion__WatchtowerToken: "${WATCHTOWER_TOKEN}"
      Webhooks__Whatsapp: "https://${CUSTOMER}api.${DOMAIN}/api/WbWebhooks"
      Webhooks__Salla: "https://${CUSTOMER}api.${DOMAIN}/api/WbStoreWebhooks/salla"
      Webhooks__Zid: "https://${CUSTOMER}api.${DOMAIN}/api/WbStoreWebhooks/zid"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      # Per-customer bind-mounts → survive image upgrades & watchtower pulls.
      - ./etc:/etc/falconerp
      - ./uploads:/app/wwwroot/uploads
      - ./app-data:/app/App_Data          # servers.xml + DataProtection keys
    healthcheck:
      disable: true
    networks:
      erpnet:
        # The Angular image's nginx proxies to the hostname "falconerpapi".
        # A per-network alias keeps a unique container name per customer while
        # nginx still resolves the API on each customer's own network.
        aliases:
          - falconerpapi
    restart: unless-stopped

  web:
    image: ${WEB_IMAGE}
    container_name: ${CUSTOMER}
    ports:
      - "${WEB_PORT}:80"
    environment:
      API_URL: "https://${CUSTOMER}api.${DOMAIN}/api"
    volumes:
      - ./etc:/etc/falconerp
    depends_on:
      - api                              # start API first so nginx resolves it
    healthcheck:
      disable: true
    networks: [erpnet]
    restart: unless-stopped

networks:
  erpnet:
    name: ${CUSTOMER}erp-net
    driver: bridge
YAML
  echo "$dir"
}

dc() {  # run compose for the current NAME's stack
  local dir; dir="$(customer_dir)"
  [[ -f "$dir/docker-compose.yml" ]] || die "No stack for '$NAME'. Run install first."
  compose -p "$NAME" --project-directory "$dir" -f "$dir/docker-compose.yml" "$@"
}

# ---- shared watchtower (one per host, no port collision) --------------------
ensure_watchtower() {
  local dir="$BASE_DIR/.falcon-watchtower"   # dot-hidden, out of the customer list
  mkdir -p "$dir"
  cat > "$dir/docker-compose.yml" <<YAML
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: falcon-watchtower
    pull_policy: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_LABEL_ENABLE=false        # watches EVERY container on the host
      - WATCHTOWER_HTTP_API_UPDATE=true
      - WATCHTOWER_HTTP_API_PERIODIC_POLLS=true
      - WATCHTOWER_HTTP_API_METRICS=true
      - WATCHTOWER_HTTP_API_TOKEN=$WATCHTOWER_TOKEN
      - DOCKER_API_VERSION=1.44
    ports:
      - "$WATCHTOWER_PORT:8080"
    restart: unless-stopped
YAML
  compose -p falcon-watchtower --project-directory "$dir" up -d
  ok "Shared watchtower running on :$WATCHTOWER_PORT (updates all customers nightly)."
}

# ---- actions ----------------------------------------------------------------
case "$ACTION" in
  install)
    need_name
    [[ -n "$API_PORT" ]] || { [[ -t 0 ]] && API_PORT="$(prompt 'API host port (e.g. 5001)')"; }
    [[ -n "$WEB_PORT" ]] || { [[ -t 0 ]] && WEB_PORT="$(prompt 'Web host port (e.g. 5021)')"; }
    [[ "$API_PORT" =~ ^[0-9]+$ ]] || die "--api-port must be a number"
    [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "--web-port must be a number"
    dir="$(write_stack)"
    dc pull
    dc up -d
    ok "Installed '$NAME'"
    echo "   API : https://${NAME}api.${DOMAIN}   (host :$API_PORT)"
    echo "   Web : https://${NAME}.${DOMAIN}      (host :$WEB_PORT)"
    echo "   Data: $dir/{etc,uploads,app-data}   (safe across upgrades)"
    [[ -n "$NO_WATCHTOWER" ]] || ensure_watchtower
    ;;
  upgrade)
    need_name
    dir="$(customer_dir)"
    [[ -f "$dir/.env" ]] || die "No stack for '$NAME'. Run install first."
    set -a; . "$dir/.env"; set +a        # reload saved ports/domain/images
    write_stack >/dev/null               # re-render compose (picks up template fixes)
    dc pull
    dc up -d
    ok "Upgraded '$NAME' to latest image. Data untouched."
    ;;
  down)
    need_name
    dc down            # NO -v: bind-mounts are host dirs, data is kept regardless.
    ok "Stopped '$NAME'. Data kept at $(customer_dir)."
    ;;
  logs)
    need_name
    dc logs -f --tail=100
    ;;
  list)
    info "Installed customers under $BASE_DIR:"
    for d in "$BASE_DIR"/*/; do        # dot-dirs (.falcon-watchtower) auto-skipped
      [[ -f "$d/.falcon" ]] && echo "  • $(basename "$d")"
    done
    echo
    docker ps --filter "label=com.docker.compose.project" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    ;;
  watchtower)
    ensure_watchtower
    ;;
  -h|--help|help)
    usage 0 ;;
  *)
    die "Unknown action '$ACTION'. Try: install | upgrade | down | logs | list | watchtower"
    ;;
esac
