#!/usr/bin/env bash
# OpenClaw Telegram-only: rootless read-only Podman pod
# Gateway (Telegram bot + browser control) + Browser sidecar (Chromium + Xvfb + noVNC)
#
# Usage:
#   ./run-openclaw-telegram.sh start       # Start the pod
#   ./run-openclaw-telegram.sh stop        # Stop and remove the pod
#   ./run-openclaw-telegram.sh restart     # Stop then start
#   ./run-openclaw-telegram.sh logs        # Tail gateway logs
#   ./run-openclaw-telegram.sh logs-browser # Tail browser sidecar logs
#   ./run-openclaw-telegram.sh status      # Show pod and container status
#   ./run-openclaw-telegram.sh setup       # Run onboarding wizard
#   ./run-openclaw-telegram.sh pairing     # List pending Telegram pairings
#   ./run-openclaw-telegram.sh approve <CODE>  # Approve a Telegram pairing code
#   ./run-openclaw-telegram.sh exec <args> # Run openclaw CLI inside the gateway
#   ./run-openclaw-telegram.sh shell       # Open a shell in the gateway container

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
POD_NAME="${OPENCLAW_POD_NAME:-openclaw}"
GW_CONTAINER="${POD_NAME}-gateway"
BR_CONTAINER="${POD_NAME}-browser"

GW_IMAGE="${OPENCLAW_GW_IMAGE:-openclaw-gateway:local}"
BR_IMAGE="${OPENCLAW_BR_IMAGE:-openclaw-browser:local}"

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-${HOME}/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-${CONFIG_DIR}/workspace}"
BROWSER_DATA_DIR="${OPENCLAW_BROWSER_DATA_DIR:-${CONFIG_DIR}/browser-data}"
ENV_FILE="${OPENCLAW_ENV_FILE:-${CONFIG_DIR}/.env}"

HOST_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
HOST_NOVNC_PORT="${OPENCLAW_NOVNC_PORT:-6080}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$BROWSER_DATA_DIR"
  chmod 700 "$CONFIG_DIR" "$WORKSPACE_DIR" "$BROWSER_DATA_DIR" 2>/dev/null || true
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # Read env vars safely (handles values without quotes)
    while IFS='=' read -r key value; do
      # Skip comments and blank lines
      [[ -z "$key" || "$key" == \#* ]] && continue
      # Strip leading/trailing whitespace from key
      key="$(echo "$key" | xargs)"
      # Export the variable
      export "$key=$value"
    done < "$ENV_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Pod lifecycle
# ---------------------------------------------------------------------------
pod_exists()   { podman pod exists "$POD_NAME" 2>/dev/null; }
pod_running()  { [[ "$(podman pod inspect "$POD_NAME" --format '{{.State}}' 2>/dev/null)" == "Running" ]]; }

do_stop() {
  if pod_exists; then
    info "Stopping pod $POD_NAME..."
    podman pod stop "$POD_NAME" 2>/dev/null || true
    podman pod rm -f "$POD_NAME" 2>/dev/null || true
    info "Pod removed."
  else
    info "Pod $POD_NAME does not exist."
  fi
}

do_start() {
  require_cmd podman
  ensure_dirs
  load_env

  if pod_exists; then
    warn "Pod $POD_NAME already exists. Use 'restart' or 'stop' first."
    exit 1
  fi

  # Verify images exist
  podman image exists "$GW_IMAGE" 2>/dev/null || error "Gateway image $GW_IMAGE not found. Build it first:\n  podman build -t $GW_IMAGE -f Dockerfile ."
  podman image exists "$BR_IMAGE" 2>/dev/null || error "Browser image $BR_IMAGE not found. Build it first:\n  podman build -t $BR_IMAGE -f Dockerfile.sandbox-browser ."

  # Verify env file has real tokens (not placeholders)
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    error "OPENCLAW_GATEWAY_TOKEN is not set. Edit $ENV_FILE."
  fi

  info "Creating pod $POD_NAME (ports: gateway=${HOST_GATEWAY_PORT}, noVNC=${HOST_NOVNC_PORT})..."
  podman pod create \
    --name "$POD_NAME" \
    -p "127.0.0.1:${HOST_GATEWAY_PORT}:18789" \
    -p "0.0.0.0:${HOST_NOVNC_PORT}:6080"

  # --- Browser sidecar ---
  # The entrypoint sets HOME=/tmp/openclaw-home and creates .chrome, .config,
  # .cache under it.  We mount the persistent browser-data volume at /browser-data
  # and then the entrypoint wrapper symlinks it into place.
  info "Starting browser sidecar ($BR_CONTAINER)..."
  podman run -d \
    --pod "$POD_NAME" \
    --name "$BR_CONTAINER" \
    --read-only \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,size=512m \
    --tmpfs /dev/shm:rw,size=512m \
    -v "${BROWSER_DATA_DIR}:/browser-data:rw" \
    -e OPENCLAW_BROWSER_HEADLESS=0 \
    -e OPENCLAW_BROWSER_ENABLE_NOVNC=1 \
    --entrypoint /bin/bash \
    "$BR_IMAGE" \
    -c '
      # Set up HOME in writable /tmp with persistent chrome profile from /browser-data
      export HOME=/tmp/openclaw-home
      export DISPLAY=:1
      export XDG_CONFIG_HOME="${HOME}/.config"
      export XDG_CACHE_HOME="${HOME}/.cache"
      mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"
      # Symlink persistent chrome data into HOME
      ln -sfn /browser-data "${HOME}/.chrome"
      # Start Xvfb, Chromium, socat CDP relay, noVNC — same as original entrypoint
      exec openclaw-sandbox-browser
    '

  # Wait for Chromium CDP to become reachable inside the pod
  info "Waiting for Chromium CDP (up to 30s)..."
  for i in $(seq 1 60); do
    if podman exec "$BR_CONTAINER" curl -sS --max-time 1 "http://127.0.0.1:9222/json/version" >/dev/null 2>&1; then
      info "Chromium CDP is ready."
      break
    fi
    if [[ $i -eq 60 ]]; then
      warn "Chromium CDP did not become ready in 30s. Check: podman logs $BR_CONTAINER"
    fi
    sleep 0.5
  done

  # --- Gateway ---
  info "Starting gateway ($GW_CONTAINER)..."

  ENV_FILE_ARGS=()
  [[ -f "$ENV_FILE" ]] && ENV_FILE_ARGS+=(--env-file "$ENV_FILE")

  podman run -d \
    --pod "$POD_NAME" \
    --name "$GW_CONTAINER" \
    --read-only \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,size=256m \
    --tmpfs /home/node/.cache:rw,noexec,nosuid,size=128m \
    -v "${CONFIG_DIR}:/home/node/.openclaw:rw" \
    -v "${WORKSPACE_DIR}:/home/node/.openclaw/workspace:rw" \
    -e HOME=/home/node \
    -e TERM=xterm-256color \
    -e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
    "${ENV_FILE_ARGS[@]}" \
    "$GW_IMAGE" \
    node dist/index.js gateway --bind "$GATEWAY_BIND" --port 18789

  info "Pod $POD_NAME started."
  info "  Gateway dashboard : http://127.0.0.1:${HOST_GATEWAY_PORT}/"
  info "  noVNC (CAPTCHAs)  : http://127.0.0.1:${HOST_NOVNC_PORT}/vnc.html"
  info "  Gateway logs      : podman logs -f $GW_CONTAINER"
  info "  Browser logs      : podman logs -f $BR_CONTAINER"
  info ""
  info "Next steps:"
  info "  1. Edit ~/.openclaw/.env with your TELEGRAM_BOT_TOKEN and ANTHROPIC_API_KEY"
  info "  2. Edit ~/.openclaw/openclaw.json — set allowFrom to your Telegram user ID"
  info "  3. Restart: $0 restart"
  info "  4. DM your bot, then: $0 approve <CODE>"
}

do_restart() {
  do_stop
  do_start
}

do_status() {
  if pod_exists; then
    podman pod ps --filter "name=$POD_NAME" --format "table {{.Name}}\t{{.Status}}\t{{.Containers}}"
    echo ""
    podman ps --pod --filter "pod=$POD_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  else
    info "Pod $POD_NAME does not exist."
  fi
}

do_logs() {
  local container="${1:-$GW_CONTAINER}"
  podman logs -f "$container"
}

do_setup() {
  require_cmd podman
  ensure_dirs
  load_env

  [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]] && error "OPENCLAW_GATEWAY_TOKEN not set. Edit $ENV_FILE."

  ENV_FILE_ARGS=()
  [[ -f "$ENV_FILE" ]] && ENV_FILE_ARGS+=(--env-file "$ENV_FILE")

  podman run --rm -it \
    --read-only \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,size=256m \
    --tmpfs /home/node/.cache:rw,noexec,nosuid,size=128m \
    -v "${CONFIG_DIR}:/home/node/.openclaw:rw" \
    -v "${WORKSPACE_DIR}:/home/node/.openclaw/workspace:rw" \
    -e HOME=/home/node \
    -e TERM=xterm-256color \
    -e BROWSER=echo \
    -e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
    "${ENV_FILE_ARGS[@]}" \
    "$GW_IMAGE" \
    node dist/index.js onboard
}

do_exec() {
  podman exec -it "$GW_CONTAINER" node dist/index.js "$@"
}

do_shell() {
  podman exec -it "$GW_CONTAINER" /bin/bash
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-help}" in
  start)
    do_start
    ;;
  stop)
    do_stop
    ;;
  restart)
    do_restart
    ;;
  status)
    do_status
    ;;
  logs)
    do_logs "$GW_CONTAINER"
    ;;
  logs-browser)
    do_logs "$BR_CONTAINER"
    ;;
  setup)
    do_setup
    ;;
  pairing)
    do_exec pairing list telegram
    ;;
  approve)
    shift
    [[ -z "${1:-}" ]] && error "Usage: $0 approve <CODE>"
    do_exec pairing approve telegram "$1"
    ;;
  exec)
    shift
    do_exec "$@"
    ;;
  shell)
    do_shell
    ;;
  help|--help|-h)
    cat <<'USAGE'
OpenClaw Telegram-only pod (rootless, read-only Podman)

Commands:
  start          Create and start the pod (gateway + browser)
  stop           Stop and remove the pod
  restart        Stop then start
  status         Show pod and container status
  logs           Tail gateway logs
  logs-browser   Tail browser sidecar logs
  setup          Run onboarding wizard (interactive)
  pairing        List pending Telegram pairing codes
  approve <CODE> Approve a Telegram pairing code
  exec <args>    Run openclaw CLI inside the gateway
  shell          Open a shell in the gateway container
  help           Show this message

Environment overrides:
  OPENCLAW_CONFIG_DIR     Config dir       (default: ~/.openclaw)
  OPENCLAW_WORKSPACE_DIR  Workspace dir    (default: ~/.openclaw/workspace)
  OPENCLAW_BROWSER_DATA_DIR  Browser data  (default: ~/.openclaw/browser-data)
  OPENCLAW_GATEWAY_PORT   Host gateway port (default: 18789)
  OPENCLAW_NOVNC_PORT     Host noVNC port   (default: 6080)
  OPENCLAW_GW_IMAGE       Gateway image     (default: openclaw-gateway:local)
  OPENCLAW_BR_IMAGE       Browser image     (default: openclaw-browser:local)
USAGE
    ;;
  *)
    error "Unknown command: $1. Run '$0 help' for usage."
    ;;
esac
