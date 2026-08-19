#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_pm2

c_info "PM2 processes"
pm2 list

c_info "Relay processes"
for proc in "$SERVER_PROC" "$TUNNEL_PROC"; do
  if pm2_has "$proc"; then
    printf '  %-14s registered\n' "$proc"
  elif [ "$proc" = "$TUNNEL_PROC" ] && ! tunnel_enabled; then
    printf '  %-14s not used (RELAY_TUNNEL_MODE=none)\n' "$proc"
  else
    printf '  %-14s not registered\n' "$proc"
  fi
done

printf '\nBackend URL: %s\n' "$(get_env PUBLIC_BASE_URL)"
printf 'Tunnel mode: %s\n' "$(tunnel_mode)"

printf '\nLogs:\n'
printf '  %s\n' \
  "$PM2_LOG_DIR/$SERVER_PROC-out.log" \
  "$PM2_LOG_DIR/$SERVER_PROC-error.log" \
  "$PM2_LOG_DIR/$TUNNEL_PROC-out.log" \
  "$PM2_LOG_DIR/$TUNNEL_PROC-error.log"
printf '\nFollow them with: pm2 logs %s\n' "$SERVER_PROC"
