# Relay contributor guide

Relay is a Flutter client plus a self-hosted Node.js backend for controlling
Claude Code, Codex, Antigravity (`agy`), OpenCode, and Hermes on the backend
machine. Keep public usage guidance in the root READMEs, operational detail in
`docs/handbook.md`, and security guarantees in `SECURITY.md`.

## Working safely

- Never commit hosts, tokens, QR credentials, API keys, CLI login files, or
  generated backend state.
- Preserve unrelated working-tree changes. This repository is often used while
  agents are actively running against it.
- Treat mobile, Web, desktop, and all backend operating systems as clients of
  the same HTTP/SSE, credential, session, and workdir model.
- Prefer focused tests while iterating. `scripts/build_flow.sh` also rebuilds
  Web, restarts PM2, and builds an APK. ADB installation is opt-in with
  `INSTALL_APK=1`, so run the script only when that full local deployment flow
  is intended.

## Useful commands

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub test/agent_controls_test.dart

node --check server/server.js
npm --prefix server test
npm --prefix server start

flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
./scripts/build_flow.sh
```

The Web flags are intentional: Relay disables the service worker to avoid stale
clients and bundles CanvasKit locally instead of depending on gstatic.

## Repository map

- `lib/`: shared Flutter UI, controllers, storage, HTTP/SSE transport, and
  platform adapters.
- `server/server.js`: server configuration, middleware, shared runtime state,
  scheduling, route context, and optional Web static hosting.
- `server/routes/`: API routers for metadata, push, files, chat, BTW, Swarms,
  agent login, sessions, quota, and the SSH terminal ticket.
- `server/lib/`: agent runners, settings/model discovery, persistence, auth,
  filesystem policy, history, quota, push, and orchestration helpers.
- `backends/`: Linux, macOS, and Windows install/service adapters. Each OS has
  `setup`, `start`, `stop`, `status`, and `uninstall` entry points.
- `.github/workflows/ci.yml`: runs the verification commands below on pull
  requests. Update it when those commands change.
- `scripts/`: development, deployment, and screenshot helpers.
- `test/` and `server/test/`: Flutter and Node test suites.

## Architecture invariants

### Scope and concurrency

- A device stores its active workdir locally and sends it as `X-Workdir` on
  every request. There is no global backend workdir.
- A conversation is scoped by `workdir + agent + sessionId`. Each agent context
  supports at most eight named sessions; `Main` keeps the legacy scope key and
  cannot be deleted.
- Turns in the same exact conversation scope serialize through `scopeChains`.
  Different sessions and different Swarm members may run concurrently.
- Agent controls are broader than a conversation: model, effort, permission,
  and fast mode persist per `workdir + agent`, so all named sessions and devices
  in that context share them.

### Agents and controls

- `server/lib/agents.js` is the process-runner boundary. Pass per-request state
  through `runAgent(..., { workdir, settings, sessionKey })`; do not add globals.
- `server/lib/agent-options.js` owns option validation and exact CLI argv.
  `server/lib/agent-settings.js` persists normalized solo-chat settings.
- Fast mode is supported only by Claude Code and Codex and defaults off. Claude
  receives a `fastMode` settings override; Codex receives an explicit
  `service_tier="fast"` or `service_tier="default"` override.
- Codex models and model-specific reasoning levels come from structured CLI
  metadata, with bundled/cache/static fallbacks. Do not reintroduce binary
  string scanning for Codex model ids.
- `GET /api/agents` returns all five known agents with install/auth/usability
  state. Claude, Codex, and Agy require OAuth; OpenCode and Hermes credentials
  are managed on the host and become selectable when installed.
- The in-app OAuth bridge uses the backend host's `script -qfec` PTY utility.
  Keep the process output redacted and never return credential values.

### Backend modules and persistence

- Each route factory receives dependencies through `routeContext`. When a route
  destructures a new helper, add it to the context in `server/server.js`.
- Use `server/lib/json-store.js` for JSON state: cached reads, atomic replace,
  and owner-only file permissions. Do not create ad hoc read/modify/write stores.
- A generated state file may accept a `RELAY_*_FILE` absolute-path override so
  its module is testable without touching deployment state. When adding one to a
  file that the file API denies, take the path from the owning module rather than
  rebuilding it in `server/lib/filesystem.js`.
- New notifications should go through `server/lib/notify.js`, which fans out to
  configured Web Push and FCM channels.
- Prompts are passed as one argv token and are capped by `PROMPT_MAX_BYTES`.
  Preserve that validation in every chat path.

### Client boundaries

- `lib/core/backend/api_transport.dart` is the shared authenticated transport.
  Reuse it instead of duplicating base URL, bearer token, device headers, or
  error handling.
- Credential decryption and large history decoding stay off the UI isolate.
- `MachineCredentialsStore`, `DeviceIdStore`, and `WorkdirStore` use static
  caches because multiple instances exist. Every new write path must invalidate
  the corresponding cache.
- The shared `/api/events` stream is workdir-aware and has an idle timeout so a
  dead connection reconnects. Preserve scope filters when adding events.

### Files, Swarms, and side conversations

- The file API accepts absolute paths and is filesystem-wide by default, but
  always applies the precise sensitive-path denylist and optional
  `RELAY_FS_ROOTS` allowlist in `server/lib/filesystem.js`.
- A Swarm owns one canonical transcript and private resumable sessions per
  member. One human message snapshots the transcript once, then mentioned
  members run in parallel from their own delta prompts.
- Swarm configuration is stored under the workspace that lists it, while its
  chosen work tree is the directory members actually use.
- BTW is read-only and isolated from the main session. Claude forks natively;
  Codex and Agy clone their native persisted conversations before resuming the
  side scope.
- The SSH terminal exchanges the bearer credential for a short-lived,
  single-use WebSocket ticket. Never put the bearer token in a socket URL. A
  token record owns one resumable PTY, which runs with the full permissions of
  the backend OS user and is not constrained by the file API denylist. Keep its
  bundled `RelayTerminalMono` family as xterm's primary font: using generic
  `monospace` can produce overly wide character cells in Chromium.

## Local state and secrets

Generated files under `server/` include `.env`, `tokens.json`, credentials,
agent/chat sessions, history, settings, groups, quota state/schedules, usage
cache, and push/FCM stores. They are deployment state, not fixtures. Keep them
out of patches and release archives. `server/models-extra.json` is also a local
override, not a shared catalog.

## Verification expectations

- Flutter-only changes: format touched Dart files, run analyze, then focused and
  full Flutter tests when practical.
- Backend changes: run `node --check` on touched JavaScript and
  `npm --prefix server test`.
- Cross-stack API changes: verify both suites and keep old payload parsing safe
  when adding response fields.
- Documentation changes: verify local Markdown links, commands, environment
  names, and English/Chinese README parity against code rather than old docs.
- Release bumps touch four places, which drift apart if any is missed:
  `pubspec.yaml`, `server/package.json`, `_applicationVersion` in
  `lib/features/settings/app_settings_screen.dart`, and a `CHANGELOG.md` entry.
