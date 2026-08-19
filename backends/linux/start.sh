#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_pm2
require_setup

cd "$SERVER_DIR"
if tunnel_enabled; then
  c_info "Starting Relay backend + Cloudflare Tunnel (PM2: $SERVER_PROC, $TUNNEL_PROC)"
else
  c_info "Starting Relay backend (PM2: $SERVER_PROC)"
fi

# ecosystem.config.js omits the tunnel app when RELAY_TUNNEL_MODE=none, and
# --update-env re-reads server/.env for processes that already exist.
pm2 start ecosystem.config.js --update-env
pm2 save >/dev/null 2>&1 || true

c_info "Started. Check it with ./backends/linux/status.sh"
