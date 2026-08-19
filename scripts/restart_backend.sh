#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"
PM2_APP_NAME="${PM2_APP_NAME:-relay-server}"
PM2_ECOSYSTEM="${PM2_ECOSYSTEM:-ecosystem.config.js}"

env_value() {
  local key="$1"
  local value="${!key:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return
  fi
  if [[ -f "$SERVER_DIR/.env" ]]; then
    local line
    line="$(grep -E "^${key}=" "$SERVER_DIR/.env" | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      printf '%s' "${line#*=}"
    fi
  fi
}

PORT_VALUE="$(env_value PORT)"
PORT_VALUE="${PORT_VALUE:-8787}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${PORT_VALUE}/api/health}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 127
  fi
}

check_backend_js() {
  if [[ "${SKIP_CHECK:-0}" == "1" ]]; then
    printf '\n==> skipping backend JS syntax check (SKIP_CHECK=1)\n'
    return
  fi
  printf '\n==> checking backend JS syntax\n'
  while IFS= read -r -d '' file; do
    node --check "$file"
  done < <(find "$SERVER_DIR" -name '*.js' -not -path '*/node_modules/*' -print0)
}

restart_pm2_app() {
  cd "$SERVER_DIR"
  printf '\n==> restarting PM2 app: %s\n' "$PM2_APP_NAME"
  if pm2 describe "$PM2_APP_NAME" >/dev/null 2>&1; then
    if pm2 restart "$PM2_APP_NAME" --update-env; then
      return
    fi
    printf 'pm2 restart failed; recreating %s from %s\n' \
      "$PM2_APP_NAME" "$PM2_ECOSYSTEM"
    pm2 delete "$PM2_APP_NAME" >/dev/null 2>&1 || true
  fi
  pm2 start "$PM2_ECOSYSTEM" --only "$PM2_APP_NAME" --update-env
}

# /api/health sits behind requireAuth and this script holds no device token, so
# the healthy answer here is 401, not 200 — any HTTP status proves the process is
# listening and Express is serving. Only a connection failure (curl reports 000)
# or a 5xx means the backend is not back yet. Polling with a bad token also costs
# one of the 15 auth failures per minute the brute-force guard allows, which is
# another reason this must pass on the first try rather than by retrying.
wait_for_health() {
  if ! command -v curl >/dev/null 2>&1; then
    printf '\n==> curl not found; skipped health check for %s\n' "$HEALTH_URL"
    return
  fi
  printf '\n==> waiting for backend to answer: %s\n' "$HEALTH_URL"
  local status
  for attempt in {1..20}; do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" || true)"
    case "$status" in
      000|'' | 5??)
        printf 'backend not ready yet (%s/20, HTTP %s)\n' "$attempt" "${status:-none}"
        ;;
      *)
        printf 'Backend is up (HTTP %s).\n' "$status"
        return
        ;;
    esac
    sleep 1
  done
  printf 'Backend did not answer at %s (last status: %s)\n' \
    "$HEALTH_URL" "${status:-none}" >&2
  exit 1
}

require_cmd node
require_cmd pm2

check_backend_js
restart_pm2_app
pm2 save >/dev/null 2>&1 || true
wait_for_health

printf '\nDone. %s restarted.\n' "$PM2_APP_NAME"
