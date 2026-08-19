# Security

Relay is a self-hosted control surface for CLI coding agents. It protects the
connection to its own API and limits what its file endpoints expose, but it is
not a sandbox for the agents it launches.

## Trust boundary

Relay has two parts:

- a Flutter client for mobile, Web, and desktop;
- a Node.js backend on a machine you control, running with that machine user's
  filesystem and process permissions.

There is no Relay-hosted account or control plane. The client connects only to
the backend URL in an imported credential. Prompts, files, agent output, and CLI
credentials stay between your devices, backend host, and the CLI providers you
already use.

## Credentials and device tokens

The credential generator creates a `relay.credentials.v1` QR/JSON envelope with
the machine id/name, backend URL, and one bearer token. The envelope uses
PBKDF2-HMAC-SHA256 with 600,000 iterations plus AES-256-GCM with a random salt
and nonce. A passphrase entered at the interactive prompt is not saved by the
generator. `--passphrase` and `RELAY_CREDENTIAL_PASSPHRASE` exist for unattended
setup and should be avoided otherwise: the flag is visible in process listings
and can persist in shell history, while the environment variable is visible to
the process and can persist in `.env` or another launcher configuration.

The backend stores bearer-token records and metadata in `server/tokens.json`.
That file is a secret and is written owner-only. Native
clients store imported credentials through platform secure storage. Web storage
inherits the security of the browser profile and origin; use a trusted device
and private profile for sensitive backends.

Recommended practice:

- generate a separate credential for every device;
- treat generated QR/JSON files as secrets even though they are encrypted;
- revoke and delete a token when a device is lost or retired;
- regenerate credentials after changing `PUBLIC_BASE_URL`;
- never commit `.env`, tokens, credential exports, push keys, history, sessions,
  agent settings, groups, CLI login state, or FCM service-account files.

Generating a new credential deletes old QR/JSON export files, but it does not
revoke previously issued device tokens. The backend status panel lists token
ids, device metadata, and last-use time so each old token can be revoked and
then deleted deliberately.

## API protections

Every HTTP `/api/*` endpoint requires `Authorization: Bearer <token>`. Until at
least one token exists, protected routes fail with `TOKEN_NOT_CONFIGURED` rather
than running unauthenticated. The terminal WebSocket upgrade redeems the
single-use ticket described below instead of accepting a bearer token in its
URL.

Implemented controls include:

- timing-safe comparison of hashed candidate and stored active-token values;
- device id/name and last-use metadata without exposing token values;
- token revocation and deletion;
- a 600-request/minute/IP limit for ordinary API requests;
- a separate 15-failed-auth-attempt/minute/IP limit;
- streaming chat/SSE and file-transfer routes excluded from the general
  request counter while still requiring authentication;
- `trust proxy` restricted to loopback so a direct client cannot spoof
  `X-Forwarded-For`;
- a startup warning when a routable public URL uses plaintext HTTP.

Relay never logs a CLI agent in. Every agent's credential is created on the
backend host with that CLI's own login flow or provider configuration.
`server/lib/agent-status.js` reads authentication state and, for Claude Code and
Codex, the stored OAuth expiry timestamp. `server/lib/usage.js` additionally
reads their OAuth tokens for quota queries and can refresh an expired access
token in the CLI's credential file. Token values may therefore be sent to the
provider's OAuth and API endpoints, but neither Relay's API nor the app ever
receives them.

Quota reporting is not passive for every provider. Codex usage discovery sends
a minimal Responses request to obtain quota headers. The enabled-by-default
Claude keepalive sends a one-output-token request when its five-hour window is
idle. Either request can consume provider quota; disable the latter with
`ENABLE_CLAUDE_KEEPALIVE=false` if that tradeoff is unwanted.

## SSH terminal

The **Enter SSH** surface is a remote interactive login shell backed by a PTY;
it does not connect to or expose the host's SSH daemon. The shell runs as the
same OS user as the Relay backend and starts in that user's home directory.

Creating a terminal connection first requires the normal bearer token over an
authenticated HTTP request. The backend returns a random ticket that expires
after 30 seconds and can be redeemed only once through the WebSocket endpoint.
The bearer token is never placed in the WebSocket URL. Each device-token record
owns at most one terminal: a newer attachment replaces an older window, while a
detached shell is retained for 12 hours by default so the client can resume it.
Revoking the owning device token closes its attached socket and PTY; token-file
changes made by the credential CLI are detected by the terminal heartbeat.
Terminal replay output is bounded and held in process memory only; Relay does
not write terminal transcripts to disk. Client-only rendering choices such as
Light/Dark colors and terminal font spacing do not change this authorization or
process boundary.

This shell is intentionally more powerful than the file API. It is **not**
restricted by `RELAY_FS_ROOTS` or the sensitive-path denylist and can read,
write, and execute anything available to the backend OS user. Possession of a
valid device token therefore permits arbitrary command execution as that user.
Use a dedicated non-root account, revoke lost-device tokens immediately, and do
not expose Relay without TLS.

## File API protections

By default, the file browser accepts absolute paths anywhere the backend user
can access. It always rejects these current sensitive locations:

- `server/tokens.json`, `server/.env`, and `server/credentials/`;
- `server/push-subscriptions.json` and `server/fcm-tokens.json`;
- `~/.ssh`;
- Claude Code's `.credentials.json` and Codex's `auth.json`.

The same policy applies to listing, upload, download, and atomic temp-file
variants. A directory download is also rejected when its tree would contain a
denied path.

This list is intentionally precise, not a promise to detect every secret. It
does not automatically cover arbitrary OpenCode, Hermes, provider, or
service-account files. Set `RELAY_FS_ROOTS` to a comma-separated allowlist of
absolute directories and run Relay as a restricted OS user. The allowlist
limits the file API only; it does not change what a launched CLI can access.

Uploads stream to a temporary file and default to 100 MB. Downloads default to
300 MB. Configure smaller proxy and Relay limits when the deployment does not
need those sizes. Unix directory downloads invoke the host's `zip` command;
Windows uses PowerShell `Compress-Archive`.

## Production requirements

For a backend reachable beyond localhost:

- terminate TLS with a named Cloudflare Tunnel or a reverse proxy;
- bind Relay to `127.0.0.1` when the proxy/tunnel runs on the same host;
- set `PUBLIC_BASE_URL` to the exact HTTPS URL imported by clients;
- run the backend as a non-root user with access only to intended workdirs;
- configure `RELAY_FS_ROOTS`;
- keep the backend port private and forward only the TLS endpoint;
- disable proxy buffering for SSE/chat routes and set timeouts above the maximum
  agent turn duration;
- forward WebSocket upgrades for `/api/terminal/connect` and use an idle timeout
  suitable for interactive shells;
- protect backend backups, because history and session files contain raw
  unredacted conversation content.

See the [production checklist](docs/handbook.md#production-deployment).

## What Relay does not do

- It does not sandbox Claude Code, Codex, OpenCode, or Hermes.
- It cannot stop an enabled fast mode or high-permission agent from consuming
  provider quota or changing files within its effective access.
- It cannot protect an already compromised backend host or browser profile.
- It cannot make a public plaintext HTTP connection safe.
- A valid device token permits an interactive shell and remains powerful until
  it is revoked.

## Reporting issues

Do not publish a vulnerability that exposes tokens, credentials, private files,
or remote-execution paths before a fix is available. Contact the maintainer
privately, then coordinate a public advisory or issue after remediation.
