# Changelog

## Unreleased

### Added

- SSH terminal key bar on Android and iOS with Ctrl, Shift, Esc, Tab, and the
  arrow keys a phone keyboard lacks. Ctrl and Shift latch for the next key,
  typed or tapped, then release, so Ctrl then `c` sends `^C`.

### Changed

- A brand-new device now starts in `~/Relay` instead of `~/agent_deck`;
  `RELAY_DEFAULT_DIR` still overrides it.
- The chat header names the current workspace, with `Agent - Session` below it.
- The home page shows the current machine, the current workspace, up to three
  recent workspaces (from `GET /api/workdirs/recent`), and a Tutorial section,
  replacing recent swarms, agent sessions, and the Manage credentials shortcut.
- The drawer lists CLI agents above Swarm.
- Tapping the machine opens a Machine details page: Enter SSH and CLI agent
  status (both moved from Manage credentials), device tokens, then the backend
  status.
- File system: Set as work path is now the primary button, ahead of Upload file;
  swiping right on the file list goes up one folder.
- Usage query no longer opens on a full-screen spinner: the Claude Code and
  Codex cards show at once and each fills in as soon as its own quota answers
  (`GET /api/usage?source=claude|codex`), so a slow Codex probe no longer holds
  back Claude.

### Fixed

- Codex authentication status now follows its app-server `account/read`
  contract on an explicit recheck, including managed ChatGPT, API-key, external
  token, and host-managed provider modes. Relay no longer treats the one-hour
  ID-token `exp` as a login deadline: managed ChatGPT credentials refresh
  automatically, and Codex shows no misleading expiry countdown. Transient
  verification failures also remain errors instead of being reported as a
  required login.

## 0.1.5 - 2026-08-19

### Removed

- Antigravity (`agy`) support. The CLI agent list is now Claude Code, Codex,
  OpenCode, and Hermes, and the usage screen reports Claude Code and Codex only.
  This drops the agy runner, BTW conversation cloning, model discovery, OAuth
  login, and the local language-server quota probe, along with
  `AGY_QUOTA_PROBE_TIMEOUT_MS`.
- The browser-only OAuth login mode (`authMode` / `requiresCode` on the login
  SSE stream), which existed solely for Antigravity. Every remaining OAuth agent
  now uses its own host-side login flow.
- BTW side conversations, for Claude Code and Codex alike. This drops the
  `/api/btw` routes, the side-scope session keys and their transcripts, the
  BTW button and dialog in the app, and the session-forking each agent needed
  to support them.
- The in-app OAuth login bridge for Claude Code and Codex. This drops the
  `/api/agent-auth/*` routes, the backend PTY that ran the CLI's own login
  command through `script -qfec`, and the login dialog in the app. Log in on
  the backend host, as OpenCode and Hermes already required.

### Added

- Swarm members can now summon each other. An `@mention` in a member's reply
  hands the floor to that teammate, so a round continues in waves instead of
  ending when the human's mentions are done; each wave snapshots the transcript
  again, so the newly summoned members see what was just said. Every member's
  prompt now lists its teammates and the `@name` that reaches each, because a
  member that does not know summoning works will never use it.
  `RELAY_SWARM_MAX_HOPS` bounds the agent-driven waves that follow one human
  message (default 3; 0 keeps summoning human-only), a member cannot summon
  itself, and a failed or cancelled turn summons no one. The transcript records
  which member summoned each reply.
- Credential expiry for Claude Code and Codex on the **Manage credentials**
  screen: the days left before the next login on the backend host, or the days
  since the credential expired. `/api/agents` reports it as
  `credentialExpiresAt`, read from the timestamps the two CLIs already store
  next to their tokens.

- The backend keeps Claude's five-hour quota window cycling with one minimal
  request whenever the window is idle, so its reset time is no longer reported
  as unknown after a lapse. The request can consume quota; set
  `ENABLE_CLAUDE_KEEPALIVE=false` to opt out.
- Linux service scripts (`start.sh`, `stop.sh`, `status.sh`, `uninstall.sh`)
  alongside the existing macOS and Windows sets.
- An MIT `LICENSE` and a GitHub Actions workflow running the analyzer and both
  test suites.
- Test coverage for the file API access policy, the device-token store, and
  quota schedules.

### Changed

- Reworked the English and Chinese READMEs into a visual product tour with
  Chromium screenshots captured against isolated demo data, a clearer system
  diagram, and a shorter path from project overview to backend setup.

- The composer's Model / Effort / Permission controls and the quota screens now
  open without waiting on the network. The option catalog describes the
  installed CLI, not the current workdir, so it is cached and the buttons render
  at their final size on the first frame instead of showing a spinner and then
  growing; returning from an option page adopts the selection it saved instead
  of refetching both the catalog and the settings. The usage and scheduler
  screens paint the last report immediately and refresh behind it.
- Backend option lookups no longer spawn processes on the hot path. Every
  `/api/agent-options`, `/api/agent-settings`, and agent turn re-located the CLI
  binary with a synchronous `command -v` subprocess and re-read
  `models-extra.json`, blocking the event loop (and so every SSE stream) for
  about 6 ms each, 12 ms for a settings read. Discovery now re-checks the binary
  at most once a minute, remembers hosts where a CLI is absent, and caches the
  extra-models file by mtime; a CLI update still busts the cache immediately.
  `describeAgent` went from 6.1 ms to 0.04 ms per call, `getSettings` from
  ~12 ms to 0.03 ms. `<cli> --version`, which ran on every model/effort page
  open, is cached the same way.
- Claude Code now runs as a persistent session instead of one process per turn.
  A chat keeps a single CLI process alive between messages, the way a terminal
  session does, so follow-up turns skip the cold start (roughly 3.1s to 1.5s in
  local measurement) and anything started in the background — watchers, servers,
  long-running tasks — is still running on the next turn instead of being killed
  the moment the turn ends. Cancelling a turn now interrupts it rather than
  killing the process, so the conversation survives a cancel.

  Live processes cost about 300 MB each, so an idle chat's process is closed
  after `RELAY_CLAUDE_IDLE_MS` (default 15 minutes) and at most
  `RELAY_CLAUDE_MAX_LIVE` (default 3) exist at once; a chat whose process was
  closed resumes into the same conversation on its next turn. `RELAY_CLAUDE_BIN`
  overrides which `claude` binary is driven.
- OpenCode, Hermes and Codex now run as persistent sessions too, over their
  stdio JSON-RPC servers — `acp` for the first two (Agent Client Protocol),
  `app-server` for Codex — with the same gains: follow-up turns skip the cold
  start (3.9s to 1.4s for opencode, 5.2s to 1.2s for hermes, 3.7s to 1.4s for
  codex in local measurement), and cancelling interrupts the turn instead of
  killing the conversation. Replies now stream token by token for opencode and
  hermes as well — the old opencode path could only stream whole JSON lines and
  hermes could not stream at all. OpenCode and Hermes apply settings over ACP;
  Codex applies most settings per turn, while a sandbox change reopens and
  resumes the thread without respawning the shared app-server process. No agent
  runs one process per turn any more.

  Unlike Claude, one process per agent hosts *every* chat for it, because these
  protocols give each session its own work tree. That pays the CLI's startup
  cost (~360 MB for opencode, ~90 MB for hermes) once instead of once per chat.
  Idle sessions are closed after `RELAY_AGENT_IDLE_MS` (default 15 minutes), at
  most `RELAY_AGENT_MAX_SESSIONS` (default 4) are live per agent, and the process
  exits with its last session; a chat whose session was closed reloads into the
  same conversation on its next turn.

  Approval prompts now reach Relay directly. Until there is an approval UI, the
  "Bypass" / "Auto-approve (yolo)" tiers approve them and the "Ask" / "Cautious"
  tiers refuse — deterministic, where the old non-interactive runs could stall.

  Background work started by a turn now outlives it for Claude, OpenCode and
  Hermes. Codex is the exception: its sandbox kills the process group of each
  command as that command returns, so background work there survives only if it
  detaches into its own session (`setsid`).
- Deleting or clearing a chat session now removes Relay history and its stored
  resume id, then requests CLI-side transcript deletion for all four agents.
  External CLI deletion remains best effort.
- `server/.env.example` documents the remaining supported settings, including
  the state-file overrides and the keepalive retry interval.
- The denylist that protects `tokens.json` now follows `RELAY_TOKENS_FILE`
  instead of assuming the default location.
- Documented that the credential generator also accepts a passphrase from
  `--passphrase` or `RELAY_CREDENTIAL_PASSPHRASE`.

### Fixed

- Chat-history search now jumps to the matched message reliably and highlights
  the search term after the destination conversation loads.

## 0.1.4 - 2026-07-13

### Added

- A resumable SSH terminal for mobile, Web, and desktop under **Manage
  credentials**, with one PTY per device credential, Light/Dark colors, and
  short-lived single-use WebSocket tickets.
- A Fast mode switch in the solo-chat composer for Claude Code and Codex. The
  setting defaults off and is shared by every named session in the same
  workdir/agent context.

### Changed

- Bundled a terminal monospace font for the Web SSH terminal so Chromium does
  not render excessive horizontal spacing between characters.
- Codex model and reasoning-effort choices now come from the installed CLI's
  structured catalog, including model-specific supported effort levels and
  defaults. Updating the CLI refreshes both choices without a Relay release.
- Consolidated contributor, deployment, and platform documentation around the
  current codebase; removed completed task specs, broken memory notes, duplicate
  platform pages, and roadmap-as-changelog copies.

### Fixed

- Removed false Codex model ids produced by binary string scanning and repaired
  stale or unsupported model/effort selections in solo chats and Swarms.
- CLI update failures are no longer reported as "Already up to date."
- Repaired the Linux setup entry after the one-command installer moved under
  `scripts/`.

## 0.1.3 - 2026-06-27

### Added

- First-run **Deploy backend** guide in the app, with Linux, macOS, and Windows
  setup commands and the same credential-import flow as the README.
- Background turn tracking for single-agent sessions, so long-running turns can
  continue while the user moves between sessions.
- Running-session indicators in the CLI agent drawer.
- Installed/authenticated/usable status for all five agents, selection gating,
  and in-app OAuth flows for Claude Code, Codex, and Antigravity on compatible
  backend hosts.
- More public-facing README structure, a dedicated security model, and release
  preparation documentation.

### Changed

- New-session creation no longer blocks just because another session is running.
- Credential import screens now surface scan, upload, and paste flows more
  clearly across mobile, Web, and desktop.
- Flutter and backend package metadata are bumped for the 0.1.3 release.

### Fixed

- Several chat/session state edges around switching sessions while work is still
  in progress.
- Documentation drift around production deployment and current version naming.

## 0.1.2 - 2026-06-20

- Added app screenshots and a more complete README.
- Added native agent icons and improved chat composer controls.
- Documented desktop build requirements and production deployment notes in the
  handbook.

## 0.1.0 - 2026-06-11

- First public baseline after the Relay rename.
- Hardened backend integrity, credential handling, route structure, and frontend
  state handling.
