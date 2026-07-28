#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_pm2

# Stop the tunnel first so it stops advertising a backend that is going away.
for proc in "$TUNNEL_PROC" "$SERVER_PROC"; do
  if pm2_has "$proc"; then
    c_info "Stopping $proc"
    pm2 stop "$proc" >/dev/null
  else
    c_warn "$proc is not registered with PM2; nothing to stop."
  fi
done

pm2 save >/dev/null 2>&1 || true
c_info "Stopped. The processes stay registered, so ./backends/linux/start.sh resumes them."
