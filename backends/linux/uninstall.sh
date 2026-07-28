#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_pm2

c_info "Removing Relay PM2 processes"
for proc in "$TUNNEL_PROC" "$SERVER_PROC"; do
  if pm2_has "$proc"; then
    pm2 delete "$proc" >/dev/null
    printf '  deleted %s\n' "$proc"
  else
    printf '  %s was not registered\n' "$proc"
  fi
done

pm2 save >/dev/null 2>&1 || true

c_info "Removed the PM2 processes."
cat <<EOF
Backend data was left in place on purpose. Delete it yourself if you are
retiring this host:

  $SERVER_DIR/.env
  $SERVER_DIR/tokens.json          (revoke device tokens first:
                                    npm --prefix server run credential -- --list-tokens)
  $SERVER_DIR/credentials/
  $SERVER_DIR/chat-history.json and the other generated JSON state files
  $PM2_LOG_DIR/$SERVER_PROC-*.log

PM2 itself, Node.js, and the CLI agents are untouched.
EOF
