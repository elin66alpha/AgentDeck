# Changelog

## 0.1.5 - 2026-07-27

### Removed

- Antigravity (`agy`) support. The CLI agent list is now Claude Code, Codex,
  OpenCode, and Hermes, and the usage screen reports Claude Code and Codex only.
  This drops the agy runner, BTW conversation cloning, model discovery, OAuth
  login, and the local language-server quota probe, along with
  `AGY_QUOTA_PROBE_TIMEOUT_MS`.
- The browser-only OAuth login mode (`authMode` / `requiresCode` on the login
  SSE stream), which existed solely for Antigravity. Every remaining OAuth agent
  uses the device-code flow.

### Added

- The backend keeps Claude's five-hour quota window cycling with one minimal
  request whenever the window is idle, so its reset time is no longer reported
  as unknown after a lapse. Set `ENABLE_CLAUDE_KEEPALIVE=false` to opt out.
- Linux service scripts (`start.sh`, `stop.sh`, `status.sh`, `uninstall.sh`)
  alongside the existing macOS and Windows sets.
- An MIT `LICENSE` and a GitHub Actions workflow running the analyzer and both
  test suites.
- Test coverage for the file API access policy, the device-token store, and
  quota schedules.

### Changed

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
  hermes could not stream at all — and changing the model, reasoning effort or
  permission tier applies to the live session without restarting anything.
  No agent runs one process per turn any more.

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
- Codex's /btw side chat now branches the conversation with the CLI's own
  `thread/fork` instead of copying rows and rollout files inside codex's private
  SQLite state, which removes about 180 lines of version-specific surgery
  against `~/.codex/state_5.sqlite`.
- Deleting a chat session, clearing it, or resetting its /btw side chat now
  deletes the CLI-side transcript as well, so a deleted conversation can no
  longer be resumed and no longer lingers on disk. This now covers all four
  agents.
- `server/.env.example` documents the remaining supported settings, including
  the state-file overrides and the keepalive retry interval.
- The denylist that protects `tokens.json` now follows `RELAY_TOKENS_FILE`
  instead of assuming the default location.
- Documented that the credential generator also accepts a passphrase from
  `--passphrase` or `RELAY_CREDENTIAL_PASSPHRASE`.

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
