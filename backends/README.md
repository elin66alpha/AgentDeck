# Backend setup

[中文](README.zh-CN.md) · [Deployment handbook](../docs/handbook.md#production-deployment)

Relay uses the same Node.js server and HTTP/SSE API on every backend host. The
files here only adapt dependency setup, process management, logs, and optional
Cloudflare Tunnel startup to each operating system.

## Requirements

- Node.js 18 or newer.
- At least one supported CLI installed on the backend: Claude Code, Codex,
  Antigravity (`agy`), OpenCode, or Hermes.
- The CLI must be authenticated on the host. Relay can bridge OAuth login for
  Claude, Codex, and Agy when the host provides the compatible `script` PTY
  utility; OpenCode and Hermes keys remain host-managed.
- `cloudflared` is required only for named or Quick Tunnel mode.

## Install

Run one command from the repository root:

| Backend OS | Command | Service manager |
|---|---|---|
| Linux | `./backends/linux/setup.sh` | PM2 |
| macOS | `./backends/macos/setup.sh` | per-user LaunchAgents |
| Windows | `.\backends\windows\setup.ps1` | per-user Scheduled Task |

The setup script creates `server/.env` when needed, installs server packages,
configures the selected network mode, starts the service, and runs the
credential generator. Import the generated `.relay.png` or `.relay.json` in the
app and enter the passphrase you chose.

### Network modes

1. **Direct:** use your own reachable address. The server binds to `0.0.0.0`;
   put HTTPS in front before exposing it publicly.
2. **Named Cloudflare Tunnel:** use a stable hostname in a Cloudflare zone. The
   server stays on `127.0.0.1`.
3. **Cloudflare Quick Tunnel:** useful for a trial. The generated
   `trycloudflare.com` URL may change after restart, so regenerate and re-import
   the credential when it rotates.

## Service management

### Linux

```bash
./backends/linux/status.sh
./backends/linux/start.sh
./backends/linux/stop.sh
./backends/linux/uninstall.sh
```

These wrap PM2, which remains available directly:

```bash
pm2 list
pm2 logs relay-server
pm2 restart relay-server --update-env
pm2 logs relay-tunnel
```

Linux setup requires PM2 (`npm install -g pm2`). It creates `relay-server` and,
for tunnel modes, `relay-tunnel`. Logs are under `~/.pm2/logs/` as
`relay-server-*.log` and `relay-tunnel-*.log`. `uninstall.sh` removes the PM2
processes and leaves backend data, tokens, and credentials in place. The
interactive terminal's PTY dependency is
compiled on Linux, so first-time setup also needs Python 3, `make`, and a C++
compiler (for example the Debian/Ubuntu `build-essential` package).

### macOS

```bash
./backends/macos/status.sh
./backends/macos/start.sh
./backends/macos/stop.sh
./backends/macos/uninstall.sh
```

LaunchAgents are installed under `~/Library/LaunchAgents`. Logs are under
`~/Library/Logs/Relay/` as `backend.*.log` and `tunnel.*.log`. The generated
service PATH includes common Homebrew and per-user binary locations.

### Windows

```powershell
.\backends\windows\status.ps1
.\backends\windows\start.ps1
.\backends\windows\stop.ps1
.\backends\windows\uninstall.ps1
```

Logs and PID files live under `%LOCALAPPDATA%\Relay\logs\` and
`%LOCALAPPDATA%\Relay\runtime\`. If PowerShell blocks the setup script, allow it
for the current shell only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Manual server start

For development or troubleshooting, bypass the service adapters:

```bash
cd server
npm install
cp .env.example .env
npm start
```

Generate a credential separately with `npm run credential`. See
`server/.env.example` for configuration and the handbook for production
hardening.
