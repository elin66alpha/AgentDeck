# Relay contributor guide

Relay is a Flutter client plus a self-hosted Node.js backend for controlling
Claude Code, Codex, OpenCode, and Hermes on the backend machine. Keep public usage guidance in the root READMEs, operational detail in
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

(cd server && git ls-files '*.js' | xargs -r node --check)
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
- `server/routes/`: API routers for metadata, push, files, chat, Swarms,
  sessions, quota, and the SSH terminal ticket.
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
- `server/lib/agent-options.js` owns option validation and the CLI, SDK, or
  protocol representation of each setting. `server/lib/agent-settings.js`
  persists normalized solo-chat settings.
- No agent runs one process per turn. All four keep a live session that turns
  are fed into. Every pool is a *cache*: the stored session id stays
  authoritative, so any scope without a live session cold-starts by resuming it
  and degrades to exactly the old per-turn behaviour. Do not reintroduce a
  per-turn `spawn` for an agent that has a pool.
  - `server/lib/claude-session-pool.js` — one Agent SDK process per scope.
    Settings resolve to SDK options (`claudeSdkOptions`) rather than argv, and
    are fixed for the life of a process, so a change restarts it with `resume`.
  - `server/lib/stdio-agent-pool.js` — the shared pool for the three CLIs that
    speak line-delimited JSON-RPC on stdio. It owns the process, the wire, the
    session cap, idle eviction and cancellation; a `driver` supplies the
    protocol. One process per agent hosts *all* of that agent's scopes, since
    each session carries its own `cwd`, so a large startup cost is paid once
    instead of once per chat.
    - `acp-session-pool.js` — the ACP driver (opencode, hermes). Settings apply
      over the protocol (`acpSessionOptions`) with no restart. Capabilities from
      `initialize` gate optional calls: hermes has no `session/close`, so an
      evicted session is simply dropped.
    - `codex-session-pool.js` — the codex app-server driver. `turn/start`
      returns as soon as the turn is *accepted*; the turn is settled by the
      later `turn/completed` notification. Everything except the sandbox applies
      per turn (`codexSessionOptions`), and the sandbox is what the runner
      passes as `fixedKey` so a change reopens the thread — still resuming the
      same conversation, without respawning the process.
  - Relay answers the agents' approval requests from the configured tier,
    because there is no approval UI to route them to. The runner's policy
    answers yes or no; translating that into each protocol's vocabulary is the
    driver's job (`allow_once` vs `accept` vs `approved`).
  - `runAcpAgent` in `agents.js` is the shared runner for opencode and hermes,
    which differ only by their pool and their entries in the option tables.
- Deleting or clearing a conversation goes through `purgeSession`, not
  `clearSession`: for a pooled agent it also requests CLI-side transcript
  deletion on a best-effort basis. Use `clearSession` only for the internal
  stale-session retry.
- Test files are `test/*.test.js`. Helper processes live in `test/fixtures/`,
  which the runner would otherwise try to execute as tests.
- Fast mode is supported only by Claude Code and Codex and defaults off. Claude
  receives a `fastMode` settings override; Codex receives an explicit
  `serviceTier` of `fast` or `default` on every turn.
- Codex models and model-specific reasoning levels come from structured CLI
  metadata, with bundled/cache/static fallbacks. Do not reintroduce binary
  string scanning for Codex model ids.
- `describeAgent` and `getSettings` are hot paths for option refreshes and every
  turn, so keep them free of subprocesses and per-call file reads.
  `model-discovery.js` re-locates a CLI at most once a minute and caches the
  result (including "not installed"); `agent-options.js` caches
  `models-extra.json` by mtime. A CLI update calls `clearModelDiscoveryCache`,
  which is what makes new models appear at once.
- `GET /api/agents` returns all four known agents with install/auth/usability
  state. Claude and Codex require OAuth; OpenCode and Hermes credentials are
  managed on the host and become selectable when installed.
- Every credential is created on the backend host by the CLI itself. Relay does
  not log an agent in. `server/lib/agent-status.js` reads auth state and, for
  Claude and Codex, a `credentialExpiresAt` timestamp. `server/lib/usage.js`
  separately reads and may refresh their OAuth credentials for quota reporting
  and keepalive. A token value must never reach Relay's API or app.

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
- Chat prompt payloads and generated Swarm prompts are capped by
  `PROMPT_MAX_BYTES`. Preserve that validation in every chat path.

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
  member. A round runs in waves: each wave snapshots the transcript once and
  runs everyone summoned in it in parallel from their own delta prompts. The
  human's `@mentions` open wave one; `@mentions` inside a member's reply summon
  the next wave, bounded by `RELAY_SWARM_MAX_HOPS` (default 3, 0 disables) since
  two members naming each other would otherwise never stop. A member never
  summons itself, and a failed or cancelled turn summons no one.
- Swarm configuration is stored under the workspace that lists it, while its
  chosen work tree is the directory members actually use.
- The SSH terminal exchanges the bearer credential for a short-lived,
  single-use WebSocket ticket. Never put the bearer token in a socket URL. A
  token record owns one resumable PTY, which runs with the full permissions of
  the backend OS user and is not constrained by the file API denylist. Keep its
  bundled `RelayTerminalMono` family as xterm's primary font: using generic
  `monospace` can produce overly wide character cells in Chromium.

## Local state and secrets

Generated files under `server/` include `.env`, `tokens.json`, credentials,
agent/chat sessions, history, settings, groups, quota state/schedules, usage
cache, and push/FCM stores. They are deployment state, not fixtures. Keep them,
along with any referenced FCM service-account JSON, out of patches and release
archives. `server/models-extra.json` is also a local override, not a shared
catalog.

## Verification expectations

- Flutter-only changes: format touched Dart files, run analyze, then focused and
  full Flutter tests when practical.
- Backend changes: run `node --check` on touched JavaScript and
  `npm --prefix server test`.
- Cross-stack API changes: verify both suites and keep old payload parsing safe
  when adding response fields.
- Documentation changes: verify local Markdown links, commands, environment
  names, English/Chinese README parity, and the embedded guides in
  `getting_started_screen.dart` and `deploy_backend_screen.dart` against code
  rather than old docs.
- Release bumps touch four places, which drift apart if any is missed:
  `pubspec.yaml`, `server/package.json`, `_applicationVersion` in
  `lib/features/settings/app_settings_screen.dart`, and a `CHANGELOG.md` entry.
