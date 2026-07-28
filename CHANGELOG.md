# Changelog

## 0.1.5 - 2026-07-27

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
