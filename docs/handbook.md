# Relay handbook

This is the durable operating and architecture reference for Relay. Start with
the [README](../README.md), use the [backend setup guide](../backends/README.md)
for installation, and read [SECURITY.md](../SECURITY.md) before exposing a
backend outside a trusted network.

## Production deployment

Relay carries a bearer token on every API request and can start coding agents as
the backend OS user. A stable deployment should have all of the following:

- Terminate TLS at a named Cloudflare Tunnel or a reverse proxy such as Caddy or
  Nginx. A routable `http://` `PUBLIC_BASE_URL` triggers a warning but is not
  blocked.
- Keep `HOST=127.0.0.1` when the tunnel or reverse proxy is on the same host.
  Direct mode uses `0.0.0.0`; expose it only behind HTTPS and a firewall.
- Set `PUBLIC_BASE_URL` to the exact URL imported by clients. Regenerate and
  re-import credentials after it changes.
- Run Relay as a non-root user and restrict that user's filesystem access.
- Set `RELAY_FS_ROOTS` to the absolute directories the file API should reach.
  Without it, the API is filesystem-wide except for its built-in denylist.
- Generate one credential per device. Revoke and delete old device tokens rather
  than sharing one token.
- Keep `.env`, tokens, credential exports, CLI login state, push keys, history,
  sessions, settings, groups, and quota state out of git and release archives.

### Reverse proxy requirements

- Forward normal HTTP requests and long-lived SSE responses. Disable buffering
  for `/api/events`, `/api/chat`, `/api/group/chat`, `/api/btw`, and
  `/api/agent-auth/login/start`.
- Forward `Upgrade`/`Connection` headers for the WebSocket endpoint
  `/api/terminal/connect`. Do not log its one-time `ticket` query value.
- Keep proxy timeouts above `AGENT_TIMEOUT_MS` (60 minutes by default).
- Pass the real client address in `X-Forwarded-For`. Relay trusts forwarded
  addresses only from loopback proxies.
- Match proxy body/response limits to Relay's defaults: 100 MB per upload and
  300 MB per download. Override with `UPLOAD_MAX_BYTES` and
  `DOWNLOAD_MAX_BYTES` only when the full path can handle larger transfers.
- Narrow browser access with `CORS_ALLOW_ORIGIN` when the Web app has a stable
  origin.

Relay applies a general limit of 600 ordinary API requests per minute per IP.
Long-lived chat/SSE and file-transfer endpoints are excluded from that counter
but still require authentication. Failed bearer-token attempts have a separate
15-per-minute per-IP limit.

### File API boundary

The built-in denylist currently covers Relay's token file, `.env`, generated
credential directory, Web Push/FCM token stores, `~/.ssh`, Claude Code OAuth
credentials, and Codex auth. It is not a general secret scanner and does not
cover every third-party CLI configuration. Use `RELAY_FS_ROOTS` and a restricted
backend user for the actual production boundary.

Directory downloads are zipped and rejected if the tree would contain a denied
path. Native uploads/downloads stream; Web downloads use a browser Blob and may
hold the file in memory up to the configured cap.

## Credentials and agent login

`npm run credential` creates an encrypted `relay.credentials.v1` QR/JSON
envelope containing the backend URL, machine identity, and one revocable device
token. It uses PBKDF2-HMAC-SHA256 (600,000 iterations) and AES-256-GCM. The
passphrase is prompted for interactively and is not saved. Unattended setups can
supply it with `--passphrase` or `RELAY_CREDENTIAL_PASSPHRASE`, at the cost of
exposing it to shell history or the process environment.

Useful commands from `server/`:

```bash
npm run credential
npm run credential -- --url https://relay.example.com
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

The app can scan a QR on supported mobile platforms or import it by image/file
and pasted JSON. Native clients use platform secure storage. The Web client is
subject to browser-origin storage security, so use a private profile on a
trusted device.

Relay reports separate installed, authenticated, and usable state for all five
known agents. Claude Code, Codex, and Agy are OAuth-gated. Their in-app login
bridge starts the CLI in a PTY, streams the authorization URL, and accepts a
device code where required. The bridge currently depends on GNU-compatible
`script -qfec` (normally Linux); on unsupported hosts, log in directly in a
terminal. OpenCode and Hermes credentials remain host-managed; once installed,
Relay allows their runner to start and lets the CLI report provider errors.

## SSH terminal

**Manage credentials → Enter SSH** opens an interactive PTY on the backend. It
uses the backend service account's login shell, starts in that account's home
directory, and is presented by the same Flutter terminal emulator on mobile,
Web, and desktop. The colors follow Relay's current Light/Dark theme. Terminal
text uses the bundled `RelayTerminalMono` family, backed by Cascadia Mono, with
system monospace fallbacks for missing glyphs. Keep the bundled family as the
primary font: xterm measures its character grid before painting, and Chromium
can otherwise measure a proportional fallback and produce excessively wide
horizontal cells.

An authenticated `POST /api/terminal/ticket` returns a random, single-use ticket
valid for 30 seconds. The client redeems it at `/api/terminal/connect`; the
long-lived bearer credential is not sent in the WebSocket URL. One token record
maps to one PTY. Returning to Manage credentials leaves that PTY alive, and the
next Enter SSH reconnects to it; opening it elsewhere replaces the old socket
instead of creating another shell.
Revoking the device token closes the socket and PTY. Revocations made by the
credential CLI are picked up by the terminal heartbeat without a server restart.

Detached PTYs expire after 12 hours and retain up to 2 MB of output in process
memory for replay; terminal transcripts are not written to disk.
Operators can tune these bounds with `TERMINAL_IDLE_TIMEOUT_MS` (60 seconds to 7
days) and `TERMINAL_BUFFER_MAX_BYTES` (64 KB to 16 MB), or select a shell with
`RELAY_TERMINAL_SHELL`. These settings do not make the terminal a sandbox: it
has the full permissions of the backend OS user and bypasses the file API's
denylist and `RELAY_FS_ROOTS`.

## Runtime model

### Workdirs, conversations, and settings

Each device stores its current workdir and sends it in `X-Workdir`. Backend state
then uses two related scopes:

| State | Scope |
|---|---|
| Named conversation, history, running turn, native CLI resume id | `workdir + agent + sessionId` |
| Model, effort, permission, fast mode | `workdir + agent` |
| Swarm list | workspace in `X-Workdir` |
| Swarm transcript and member sessions | Swarm id plus its chosen work tree |

An agent context supports up to eight named conversations. `Main` preserves the
legacy scope key and cannot be deleted. Turns in one exact conversation scope
queue; other sessions can continue independently. Devices on the same scope
share backend history and live events.

Agent controls are capability-aware:

| Agent | Model | Effort | Permission | Fast | Authentication |
|---|---:|---:|---:|---:|---|
| Claude Code | yes | yes | yes | yes | OAuth |
| Codex | yes | model-specific | yes | yes | OAuth |
| Antigravity | yes | no | yes | no | OAuth |
| OpenCode | yes | yes | yes | no | host-managed, optional key |
| Hermes | host config/pins | no | yes | no | host-managed key |

Fast mode defaults off, may use more quota or cost more, and is visible only in
the solo-chat composer. Relay sends an explicit Claude `fastMode` setting or
Codex `service_tier` override on every invocation. Availability still depends on
the selected model, CLI version, account, and provider. Swarm storage can retain
the field, but the current Swarm form exposes only model, effort, and permission.

Codex model and reasoning choices come from the installed CLI's structured
catalog and keep each model's advertised order/default. Updating Codex clears
the discovery cache. Other agents use their supported live or fallback catalogs;
local pins may be added in the gitignored `server/models-extra.json`.

### Swarms

A Swarm is one canonical transcript above several independent CLI sessions.
When a human message mentions multiple members, Relay snapshots the transcript
once, builds a speaker-labelled delta for each member, and runs those members in
parallel. Each member still serializes against its own private Swarm session.

At creation, a Swarm selects its work tree and per-member model, effort,
permission, nickname, and prompt/persona. The work tree cannot be changed later.
Swarms can be cleared, updated, deleted, or saved as reusable JSON templates.
Templates contain the name, member list, and member configuration; they omit the
machine-specific workdir, id, and transcript.

BTW side conversations are read-only and do not modify the main session. Claude
forks through its native CLI; Codex and Agy clone their native persisted
conversation before resuming an isolated side scope.

### Quota and notifications

The usage screen reports Claude Code, Codex, and Antigravity. Reset detection and
scheduled messages support Claude Code and Codex only. A schedule stores one
prompt per source and workspace for the next detected five-hour reset.

Claude's five-hour window only exists while it runs: once it lapses the usage API
reports no reset time, which the app can only show as unknown. The backend keeps
the window cycling by sending one minimal Claude Code request (cheapest model,
one output token) whenever the window is idle, then sleeping until just after the
new reset moment — the same effect Codex gets for free from its quota probe. Set
`ENABLE_CLAUDE_KEEPALIVE=false` to turn it off and accept the unknown state;
`CLAUDE_KEEPALIVE_MODEL` overrides the model used for the ping.

Notification delivery has three layers:

- Android, iOS, macOS, and Windows can show local notifications while Relay is
  receiving live events; Web can use browser notifications.
- Optional Web Push reaches a subscribed browser after the tab closes.
- Optional FCM reaches configured Android builds after the app is killed.

Linux desktop currently falls back to an in-app message. Fully killed iOS apps
do not have a configured offline push channel in this repository.

## API map

All HTTP `/api/*` endpoints require the imported bearer token. The terminal
WebSocket upgrade requires the short-lived ticket created by its HTTP endpoint.

- Metadata/auth: health, agents, agent options/settings/version/update,
  auth status, diagnostics, device tokens, and shared events.
- Agent OAuth: `GET /api/agent-auth/login/start`,
  `POST /api/agent-auth/login/code`, and
  `GET /api/agent-auth/login/status`.
- Chat: chat, cancellation, history, history search/export, and clear session.
- Named sessions: list/create, set active, and delete.
- Files/workdir: current workdir, absolute directory browse, upload, and
  download.
- BTW: chat, history, and clear. Cancellation uses the normal chat cancellation
  endpoint and side-scope metadata.
- Swarms: list/create, update members, delete, history, clear, chat, and cancel.
- Quota: usage, schedules, schedule replacement, and cancellation.
- Push: browser subscription/config and FCM device registration.
- SSH terminal: authenticated ticket creation plus the WebSocket PTY transport.

The route implementations in `server/routes/` are the source of truth when an
endpoint changes.

## Development and builds

### Backend and Web

```bash
cd server
npm install
cp .env.example .env
npm start
```

On Linux, `node-pty` compiles a native addon during `npm install`; install
Python 3, `make`, and a C++ compiler first (for example `build-essential` on
Debian/Ubuntu). macOS and Windows use the package's supported prebuilt binaries
when available.

To let the backend serve the Flutter Web client:

```bash
flutter pub get
flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
npm --prefix server start
```

The server serves `build/web` when present. CanvasKit is bundled locally and the
service worker is disabled to keep the self-hosted client current.

### Desktop clients

Desktop runner projects exist for Windows, macOS, and Linux, but each target
must be built on its own operating system. Windows release builds have been
exercised in this repository; macOS and Linux runners still need broader
release/secure-storage validation before being advertised as packaged releases.

```bash
flutter run -d windows       # or macos / linux
flutter build windows --release
```

Build prerequisites:

- Windows: Visual Studio with Desktop development with C++, Windows SDK, CMake,
  and Flutter. Use an ASCII-only repository path. The repository already adds
  the MSVC coroutine compatibility define needed by the notifications plugin.
- macOS: Xcode, command-line tools, CocoaPods, and Flutter desktop enabled.
- Linux: clang, CMake, Ninja, pkg-config, GTK development packages,
  `libsecret-1-dev`, and a keyring such as GNOME Keyring.

Typical artifacts are `build/windows/x64/runner/Release/`,
`build/macos/Build/Products/Release/Relay.app`, and
`build/linux/x64/release/bundle/`. Packaging, store signing, macOS notarization,
and production Android signing are not configured. Android release builds in
this repository still reuse debug signing.

## Configuration

`server/.env.example` documents supported deployment settings. The most useful
groups are:

- identity/network: `PORT`, `HOST`, `PUBLIC_BASE_URL`, tunnel variables;
- execution: `RELAY_DEFAULT_DIR`, `AGENT_TIMEOUT_MS`, `PROMPT_MAX_BYTES`,
  `RELAY_MODEL_DISCOVERY`, `CODEX_HOME`, `RELAY_TERMINAL_SHELL`, and terminal
  idle/buffer limits;
- security/files: `CORS_ALLOW_ORIGIN`, `RELAY_FS_ROOTS`, upload/download caps;
- usage: quota watch, poll interval, HTTP/probe timeouts and backoff;
- offline push: VAPID keys and `FCM_SERVICE_ACCOUNT_FILE`.

The default workdir for a new device remains `~/agent_deck` for compatibility;
after first use, each device persists its own selection.
