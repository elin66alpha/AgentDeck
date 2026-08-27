'use strict';

require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { randomUUID } = require('crypto');
const express = require('express');
const compression = require('compression');
const rateLimit = require('express-rate-limit');

const {
  DEFAULT_AGENT,
  TIMEOUT_MS,
  getAgent,
  listAgents,
  runAgent,
  purgeSession,
  shutdownPools,
  inspectCodexAccount,
} = require('./lib/agents');
const {
  WorkdirError,
  resolveWorkdir,
  getDefaultWorkdir,
  resolveRequestWorkdir,
  validateWorkdir,
} = require('./lib/workdir');
const {
  FilesystemError,
  listAbsoluteDirectory,
  prepareDownload,
  prepareDownloadAbsolute,
  resolveUploadTarget,
  resolveAbsoluteUploadTarget,
  uploadedEntry,
} = require('./lib/filesystem');
const {
  deleteRevokedTokenById,
  hasConfiguredToken,
  isTokenIdAllowed,
  isTokenAllowed,
  listTokenSummaries,
  markTokenUsed,
  revokeTokenById,
  tokenRecordForToken,
} = require('./lib/tokens');
const { createTerminalManager } = require('./lib/terminal-manager');
const { buildUsageReport } = require('./lib/usage');
const { describeAgent, CLI } = require('./lib/agent-options');
const { getSettings, setSettings } = require('./lib/agent-settings');
const push = require('./lib/push');
const fcm = require('./lib/fcm');
const { notifyAll } = require('./lib/notify');
const { startQuotaWatch } = require('./lib/quota-watch');
const { startClaudeQuotaKeepalive } = require('./lib/quota-keepalive');
const { buildDiagnostics } = require('./lib/diagnostics');
const {
  readHistory,
  upsertHistoryMessage,
  updateHistoryMessage,
  finalizeStaleStreamingHistory,
  finalizeAllStaleStreamingHistory,
  flushHistory,
  clearHistory,
  redactSensitiveText,
  searchHistory,
  markdownForConversation,
} = require('./lib/history');
const {
  LEGACY_SESSION_ID,
  MAX_SESSIONS,
  listChatSessions,
  resolveChatSession,
  createChatSession,
  setActiveChatSession,
  touchChatSession,
  deleteChatSession,
  sessionScopeKey,
} = require('./lib/chat-sessions');
const {
  agentPayload,
  createChatResponder,
  createNoopResponder,
  runAgentTurn,
  sessionPayload,
} = require('./lib/agent-turn');
const {
  cancelQuotaSchedule,
  createQuotaSchedule,
  dueQuotaSchedulesForReset,
  listQuotaSchedules,
  markQuotaScheduleFailed,
  markQuotaScheduleRunning,
  markQuotaScheduleSent,
  reconcileRunningSchedules,
} = require('./lib/quota-schedules');
const createFsRouter = require('./routes/fs');
const createChatRouter = require('./routes/chat');
const createSessionsRouter = require('./routes/sessions');
const createQuotaRouter = require('./routes/quota');
const createPushRouter = require('./routes/push');
const createMetaRouter = require('./routes/meta');
const createGroupRouter = require('./routes/group');
const createTerminalRouter = require('./routes/terminal');

const PORT = parseInt(process.env.PORT || '8787', 10);
const HOST = process.env.HOST || '127.0.0.1';
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/+$/, '');
const ENABLE_QUOTA_WATCH = process.env.ENABLE_QUOTA_WATCH !== 'false';
const ENABLE_CLAUDE_KEEPALIVE = process.env.ENABLE_CLAUDE_KEEPALIVE !== 'false';
const WEB_BUILD_DIR = path.join(__dirname, '..', 'build', 'web');
// Hard cap on a single download (file, or the uncompressed total behind a zip).
// Public tunnels can relay slowly or enforce throughput limits, so we refuse
// oversized downloads up front instead of letting the user wait on a transfer
// that will stall. Override with DOWNLOAD_MAX_BYTES if your network allows more.
const MAX_DOWNLOAD_BYTES = parseInt(
  process.env.DOWNLOAD_MAX_BYTES || String(300 * 1024 * 1024),
  10,
);
// Cap a single uploaded file. Some tunnels limit request bodies, so we refuse
// oversized uploads (the app also pre-checks before sending).
const MAX_UPLOAD_BYTES = parseInt(
  process.env.UPLOAD_MAX_BYTES || String(100 * 1024 * 1024),
  10,
);
// Cap a single chat prompt before it enters an SDK or JSON-RPC session. Swarm
// prompt construction uses the same budget so an accumulated transcript cannot
// grow without bound. Override with PROMPT_MAX_BYTES.
const MAX_PROMPT_BYTES = parseInt(
  process.env.PROMPT_MAX_BYTES || String(100 * 1024),
  10,
);
// CORS origin allowed to call the API from a browser. The bearer token is the
// real gate (browsers never attach it automatically), but narrowing this to the
// app's own origin (e.g. the PUBLIC_BASE_URL host) shrinks the surface further.
const CORS_ALLOW_ORIGIN = String(process.env.CORS_ALLOW_ORIGIN || '*').trim() || '*';

const app = express();
const terminalManager = createTerminalManager({
  isTokenActive: isTokenIdAllowed,
});
// cloudflared connects from localhost and forwards the real client IP in
// X-Forwarded-For. Trusting only loopback makes req.ip the real client behind a
// tunnel, while a direct-mode (0.0.0.0) attacker — whose socket is NOT loopback —
// cannot spoof the header, so rate limiting keys on a genuine per-client address.
app.set('trust proxy', 'loopback');

// Long-lived (SSE) and large-transfer endpoints: a single chat turn streams for
// up to AGENT_TIMEOUT_MS and uploads/downloads move hundreds of MB, so counting
// them as ordinary requests would throttle normal use. They still require auth.
function isStreamingApiPath(req) {
  // Path is relative to the '/api' mount point.
  switch (req.path) {
    case '/events':
    case '/chat':
    case '/group/chat':
    case '/fs/download':
    case '/fs/upload':
      return true;
    default:
      return false;
  }
}

// DoS guard for the authenticated API surface. Generous (the app polls status and
// can chat briskly); the real access gate is the bearer token. Keyed per client IP.
const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 600,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  skip: isStreamingApiPath,
  message: { error: 'too many requests, slow down', code: 'RATE_LIMITED' },
});

// Brute-force guard for the bearer token. Invoked only on an auth failure (see
// requireAuth), so it counts wrong-token attempts per IP and never throttles
// successful, possibly long-lived, traffic. A wrong token is rejected before it
// reaches any handler, so these requests are always short.
const authFailureLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 15,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: 'too many failed attempts, slow down', code: 'AUTH_RATE_LIMITED' },
});

const eventClients = new Set();
// Live SSE connection count per workdir, so presence checks on the broadcast
// path are O(1) instead of scanning every connected client.
const workdirPresence = new Map();
const activeRequests = new Map();
// Scopes currently executing an agent turn, keyed by `workdir\0agentKey[\0sessionId]`.
const runningScopes = new Set();
// Per-scope serial execution chains. A new message on a busy scope waits for the
// in-flight turn (the underlying `claude --resume` session cannot run two turns
// at once), then runs automatically. Maps scopeKey -> tail Promise.
const scopeChains = new Map();
function uploadTooLargeError() {
  return new FilesystemError('upload exceeds the size limit', {
    status: 413,
    code: 'FS_UPLOAD_TOO_LARGE',
  });
}

// Stream an upload body straight to disk instead of buffering it in memory
// (uploads run up to MAX_UPLOAD_BYTES; a few concurrent buffered ones used to
// spike RSS by hundreds of MB). The bytes land in a fresh temp file next to the
// target ('wx' so we never write through anything pre-existing), then rename
// into place — atomic, and replacing rather than following a symlink at the
// target. Over-limit transfers are cut off mid-stream.
function streamUploadToFile(req, targetPath, maxBytes) {
  const tmpPath = `${targetPath}.upload-${randomUUID()}`;
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(tmpPath, { flags: 'wx', mode: 0o644 });
    let received = 0;
    let failed = false;
    const fail = (err) => {
      if (failed) return;
      failed = true;
      req.unpipe(out);
      out.destroy();
      fs.unlink(tmpPath, () => {});
      reject(err);
    };
    req.on('error', fail);
    req.on('aborted', () => fail(new Error('upload aborted')));
    out.on('error', fail);
    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > maxBytes) fail(uploadTooLargeError());
    });
    out.on('finish', () => {
      if (failed) return;
      try {
        fs.renameSync(tmpPath, targetPath);
        resolve(received);
      } catch (err) {
        fail(err);
      }
    });
    req.pipe(out);
  });
}

// Compress responses before they cross the tunnel. The JavaScript and CanvasKit
// bundles dominate first-load bytes, so compression materially reduces startup
// time. `compressible` does not flag application/wasm, so allow it explicitly.
// Streaming/SSE responses set
// `Cache-Control: no-transform`, which compression honors by skipping them.
app.use(
  compression({
    filter(req, res) {
      const type = String(res.getHeader('Content-Type') || '');
      if (/application\/wasm/i.test(type)) return true;
      return compression.filter(req, res);
    },
  }),
);

app.use(express.json({ limit: '16mb' }));
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', CORS_ALLOW_ORIGIN);
  if (CORS_ALLOW_ORIGIN !== '*') res.setHeader('Vary', 'Origin');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization, X-Device-Id, X-Device-Name, X-Workdir',
  );
  res.setHeader('Access-Control-Expose-Headers', 'Content-Disposition');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  return next();
});

function requireAuth(req, res, next) {
  if (!hasConfiguredToken()) {
    return res.status(503).json({
      error: 'no app token is configured',
      code: 'TOKEN_NOT_CONFIGURED',
    });
  }
  const header = String(req.get('authorization') || '');
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!isTokenAllowed(token)) {
    // Count the failure per IP; once over the limit the limiter answers 429
    // itself, otherwise we fall through to the normal 401.
    return authFailureLimiter(req, res, () => {
      res.status(401).json({ error: 'unauthorized' });
    });
  }
  markTokenUsed(token, {
    deviceId: normalizeDeviceId(req.get('x-device-id')),
    deviceName: req.get('x-device-name'),
  });
  return next();
}

app.use('/api', apiLimiter);
app.use('/api', requireAuth);

function bearerToken(req) {
  const header = String(req.get('authorization') || '');
  return header.startsWith('Bearer ') ? header.slice(7).trim() : '';
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  return `${d}d ${h}h ${m}m ${s}s`;
}

// Warn loudly when the device token will travel in cleartext: PUBLIC_BASE_URL is
// http:// (no TLS) to a routable host. An https:// URL (reverse proxy or a
// Cloudflare Tunnel) terminates TLS and is fine; localhost is irrelevant. A
// private/LAN address still leaks the token, but only to the local network; a
// public address exposes it to anyone on the internet path.
function warnIfPlaintextTokenExposure() {
  if (!PUBLIC_BASE_URL) return;
  let url;
  try {
    url = new URL(PUBLIC_BASE_URL);
  } catch (_err) {
    return;
  }
  if (url.protocol !== 'http:') return;
  const host = url.hostname.toLowerCase();
  if (host === 'localhost' || host === '127.0.0.1' || host === '::1') return;
  const isPrivate =
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
    /^169\.254\./.test(host) ||
    host.endsWith('.local');
  console.warn('');
  console.warn('  ============================================================');
  console.warn('  ⚠  SECURITY WARNING: PUBLIC_BASE_URL uses http:// (no TLS).');
  if (isPrivate) {
    console.warn(`     Your device token is sent UNENCRYPTED to ${host}.`);
    console.warn('     This is a private/LAN address, so exposure is limited to your');
    console.warn('     local network — but anyone who can sniff that network can steal');
    console.warn('     the token and take FULL CONTROL of this machine.');
  } else {
    console.warn(`     Your device token rides NAKED over the public internet to ${host}.`);
    console.warn('     ANYONE on the network path can read it and take FULL CONTROL of');
    console.warn('     this machine (run agents, read/write any file).');
  }
  console.warn('     Fix: put TLS in front (nginx/Caddy) and use an https:// URL,');
  console.warn('     or switch to a Cloudflare Tunnel (re-run setup, pick mode 2/3).');
  console.warn('  ============================================================');
  console.warn('');
}

function sendWorkdirError(res, err) {
  if (err instanceof WorkdirError) {
    return res.status(err.status || 400).json({
      error: err.message,
      code: err.code,
      dir: err.dir,
    });
  }
  return res.status(500).json({ error: err.message });
}

function sendFilesystemError(res, err) {
  if (err instanceof FilesystemError) {
    return res.status(err.status || 400).json({
      error: err.message,
      code: err.code,
    });
  }
  return res.status(500).json({ error: err.message });
}

function queryBool(value) {
  return value === true || String(value || '').toLowerCase() === 'true';
}

function attachmentHeader(filename) {
  const fallback = String(filename || 'download')
    .replace(/[^\x20-\x7e]/g, '_')
    .replace(/["\\]/g, '_');
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}

function safeDownloadName(value, fallback = 'download') {
  const cleaned = String(value || '')
    .replace(/[^\w.-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  return cleaned || fallback;
}

function cleanupTempZip(zipPath) {
  fs.unlink(zipPath, () => {
    fs.rm(path.dirname(zipPath), { recursive: true, force: true }, () => {});
  });
}

function sendWindowsDirectoryZip(download, res) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-zip-'));
  const tempZip = path.join(tempDir, `${randomUUID()}.zip`);
  const sourcePath = path.join(download.zipCwd, download.zipEntryName);
  const powershell = process.env.POWERSHELL_BIN || 'powershell.exe';
  const child = spawn(
    powershell,
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Compress-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force',
      sourcePath,
      tempZip,
    ],
    { windowsHide: true },
  );
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.on('error', (err) => {
    cleanupTempZip(tempZip);
    if (!res.headersSent) {
      return res.status(500).json({ error: `zip failed: ${err.message}` });
    }
    return res.destroy(err);
  });
  child.on('close', (code) => {
    if (code !== 0) {
      cleanupTempZip(tempZip);
      const message = stderr.trim() || `zip exited with code ${code}`;
      if (!res.headersSent) {
        return res.status(500).json({ error: message });
      }
      return res.destroy(new Error(message));
    }
    return res.download(tempZip, download.filename, (err) => {
      cleanupTempZip(tempZip);
      if (err && !res.headersSent) {
        return sendFilesystemError(res, err);
      }
      return undefined;
    });
  });
}

function sendUnixDirectoryZip(download, res) {
  const child = spawn('zip', ['-r', '-q', '-y', '-', download.zipEntryName], {
    cwd: download.zipCwd,
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.on('error', (err) => {
    if (!res.headersSent) {
      return res.status(500).json({ error: `zip failed: ${err.message}` });
    }
    return res.destroy(err);
  });
  child.on('close', (code) => {
    if (code !== 0 && !res.destroyed) {
      const message = stderr.trim() || `zip exited with code ${code}`;
      if (!res.headersSent) {
        return res.status(500).json({ error: message });
      }
      return res.destroy(new Error(message));
    }
    return undefined;
  });
  res.setHeader('Content-Type', 'application/zip');
  res.setHeader('Content-Disposition', attachmentHeader(download.filename));
  // Defence in depth: the pre-flight size check uses the uncompressed total, so a
  // compliant zip is always smaller. If the stream ever exceeds the cap anyway
  // (e.g. files grew mid-zip), abort rather than blow the tunnel's budget.
  let sentBytes = 0;
  child.stdout.on('data', (chunk) => {
    sentBytes += chunk.length;
    if (sentBytes > MAX_DOWNLOAD_BYTES) {
      child.kill('SIGKILL');
      res.destroy();
    }
  });
  return child.stdout.pipe(res);
}

function sendDirectoryZip(download, res) {
  if (process.platform === 'win32') {
    return sendWindowsDirectoryZip(download, res);
  }
  return sendUnixDirectoryZip(download, res);
}

function sendEvent(type, payload) {
  const packet = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  const scopeWorkdir = payload && payload.scopeWorkdir;
  for (const client of eventClients) {
    // Scope events carry a scopeWorkdir and only reach devices currently in that
    // work directory, so a conversation is shared across same-path devices.
    // Events without a scopeWorkdir (such as quota_reset) reach everyone.
    if (scopeWorkdir && client.workdir !== scopeWorkdir) {
      continue;
    }
    client.res.write(packet);
  }
}

function hasPresence(scopeWorkdir) {
  if (!scopeWorkdir) return false;
  return (workdirPresence.get(scopeWorkdir) || 0) > 0;
}

function pushCategoriesFromBody(body) {
  const source =
    body &&
    body.categories &&
    typeof body.categories === 'object' &&
    !Array.isArray(body.categories)
      ? body.categories
      : body || {};
  return {
    quota: source.quota !== false,
    task: source.task !== false,
  };
}

function normalizeDeviceId(value) {
  const text = String(value || '').trim();
  if (!text) return '';
  if (!/^[A-Za-z0-9._-]{8,128}$/.test(text)) return '';
  return text;
}

// Session context = work directory + agent. Individual chat sessions hang under
// that context and each keeps its own history plus resumable CLI session. NUL
// separates parts so no real path can collide with the agent/session suffix.
const SCOPE_SEPARATOR = '\u0000';

function sessionContextKeyFor(agentKey, workdir) {
  return `${workdir}${SCOPE_SEPARATOR}${agentKey}`;
}

function scopeKeyFor(agentKey, workdir, sessionId) {
  return sessionScopeKey(sessionContextKeyFor(agentKey, workdir), sessionId);
}

// The work directory for a request: the device's x-workdir header, or the
// default for a device that has not chosen one yet. The path is created if
// missing. Throws WorkdirError for an invalid header, handled by the caller.
function requestWorkdir(req) {
  return resolveRequestWorkdir(req.get('x-workdir'));
}

const agentRequiredError = () => ({ status: 400, body: { error: 'agent is required' } });

function agentRequiredOrUnknownError(agentKey) {
  return {
    status: 400,
    body: { error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required' },
  };
}

function resolveAgentScope(req, res, options = {}) {
  const {
    agentFrom = 'params',
    agentKey,
    sessionId,
    workdir: resolvedWorkdir,
    requireSession = true,
    agentError = () => ({ status: 404, body: { error: 'unknown agent', code: 'UNKNOWN_AGENT' } }),
    beforeWorkdir,
  } = options;
  const agentValues =
    agentFrom === 'body' ? req.body : agentFrom === 'query' ? req.query : req.params;
  const key = String(agentKey === undefined ? agentValues && agentValues.agent : agentKey).trim();
  const agent = getAgent(key);
  if (!agent) {
    const { status, body } = agentError(key);
    res.status(status).json(body);
    return null;
  }
  if (typeof beforeWorkdir === 'function' && beforeWorkdir({ agent, agentKey: key }) === false) return null;
  let workdir = resolvedWorkdir;
  if (!workdir) {
    try {
      workdir = requestWorkdir(req);
    } catch (err) {
      sendWorkdirError(res, err);
      return null;
    }
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
  if (!requireSession) {
    return { agent, workdir, contextKey, session: null, scopeKey: contextKey };
  }
  const requestedSessionId = String(
    sessionId === undefined ? req.query && req.query.sessionId : sessionId,
  ).trim();
  const session = resolveChatSession(contextKey, requestedSessionId);
  if (!session) {
    res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
    return null;
  }
  return {
    agent,
    workdir,
    contextKey,
    session,
    scopeKey: scopeKeyFor(agent.key, workdir, session.id),
  };
}

// Resolve a workdir for read-only contexts (SSE subscription, status) without
// creating it; fall back to the default if the header is missing or invalid.
function eventWorkdir(req) {
  const raw = String(req.get('x-workdir') || '').trim();
  if (!raw) return getDefaultWorkdir();
  try {
    return resolveWorkdir(raw);
  } catch (_err) {
    return getDefaultWorkdir();
  }
}

// True when an agent turn is currently executing anywhere under this workdir.
function workdirBusy(workdir) {
  const prefix = `${workdir}${SCOPE_SEPARATOR}`;
  for (const key of runningScopes) {
    if (key.startsWith(prefix)) return true;
  }
  return false;
}

// Run taskFn after any in-flight turn on the same scope completes, so turns on a
// shared conversation execute one at a time. The returned promise settles with
// taskFn's result/error; the chain itself never rejects so later turns proceed.
function enqueueScope(scopeKey, taskFn) {
  const prev = scopeChains.get(scopeKey) || Promise.resolve();
  const run = prev.then(() => taskFn());
  const tail = run.catch(() => {});
  scopeChains.set(scopeKey, tail);
  tail.then(() => {
    if (scopeChains.get(scopeKey) === tail) scopeChains.delete(scopeKey);
  });
  return run;
}

// Broadcast a chat event to every device currently in the same work directory
// (including the originator, which ignores its own requestId). This is what
// makes a message sent on one device appear on the others in real time.
function broadcastScope(
  type,
  { scopeWorkdir, agent, session, requestId, deviceId, ...rest },
) {
  sendEvent(type, {
    scopeWorkdir,
    deviceId,
    requestId,
    agent: agentPayload(agent),
    ...(session ? { session: sessionPayload(session) } : {}),
    createdAt: new Date().toISOString(),
    ...rest,
  });
}

function taskCompletionSnippet(value) {
  const redacted = redactSensitiveText(value);
  const firstLine =
    redacted
      .split(/\r?\n/)
      .map((line) => line.replace(/\s+/g, ' ').trim())
      .find((line) => line.length > 0) || '';
  if (!firstLine) return 'Task completed.';
  if (firstLine.length <= 140) return firstLine;
  return `${firstLine.slice(0, 137)}...`;
}

function notifyTaskCompletion({ agent, scopeWorkdir, content }) {
  if (hasPresence(scopeWorkdir)) return;
  const body = taskCompletionSnippet(content);
  notifyAll({
    title: `${agent.label} finished`,
    titleZh: `${agent.label} 已完成`,
    message: body,
    messageZh: body,
    scopeWorkdir,
    category: 'task',
  });
}

function agentTurnDependencies() {
  return {
    broadcastScope,
    enqueueScope,
    getSettings,
    runAgent,
    runningScopes,
    scopeChains,
    touchChatSession,
    updateHistoryMessage,
    upsertHistoryMessage,
  };
}

async function runScheduledQuotaMessage(schedule) {
  const agent = getAgent(schedule.agentKey);
  if (!agent) {
    markQuotaScheduleFailed(schedule.id, `unknown agent: ${schedule.agentKey}`);
    return;
  }

  const contextKey = sessionContextKeyFor(agent.key, schedule.workdir);
  const chatSession = resolveChatSession(contextKey, schedule.sessionId);
  if (!chatSession) {
    markQuotaScheduleFailed(schedule.id, 'scheduled chat session was deleted');
    return;
  }

  const runningSchedule = markQuotaScheduleRunning(schedule.id) || schedule;
  const requestId = `quota.${schedule.id}`;
  const deviceId = 'quota-scheduler';
  const scopeKey = scopeKeyFor(agent.key, schedule.workdir, chatSession.id);

  await runAgentTurn({
    agent,
    agentKey: agent.key,
    contextKey,
    defaultErrorCode: 'SCHEDULED_AGENT_ERROR',
    dependencies: agentTurnDependencies(),
    deviceId,
    finalizeBeforeDone: true,
    finalizeContent({ content, streamedText }) {
      return String(content || streamedText || '').trim();
    },
    historyMetadata: {
      scheduledQuotaMessageId: schedule.id,
      quotaSourceKey: schedule.sourceKey,
    },
    initialProgressLines: ['Scheduled after quota reset.'],
    onBeforeDone() {
      markQuotaScheduleSent(schedule.id);
    },
    onAfterDone() {
      sendEvent('quota_schedule_sent', {
        scopeWorkdir: schedule.workdir,
        schedule: {
          ...runningSchedule,
          status: 'sent',
          sentAt: new Date().toISOString(),
        },
        message: `Scheduled ${agent.label} message was sent after quota reset.`,
        messageZh: `已在额度刷新后发送预设的 ${agent.label} 消息。`,
        createdAt: new Date().toISOString(),
      });
    },
    onBeforeError({ errorMessage }) {
      markQuotaScheduleFailed(schedule.id, errorMessage);
    },
    onAfterError({ errorMessage }) {
      sendEvent('quota_schedule_failed', {
        scopeWorkdir: schedule.workdir,
        schedule: {
          ...runningSchedule,
          status: 'failed',
          error: errorMessage,
        },
        message: `Scheduled ${agent.label} message failed: ${errorMessage}`,
        messageZh: `预设的 ${agent.label} 消息发送失败：${errorMessage}`,
        createdAt: new Date().toISOString(),
      });
    },
    prompt: schedule.prompt,
    requestId,
    responder: createNoopResponder(),
    scopeKey,
    session: chatSession,
    workdir: schedule.workdir,
  });
}

async function processDueQuotaSchedules(info) {
  const sourceKey = info && info.key;
  const due = dueQuotaSchedulesForReset(sourceKey);
  for (const schedule of due) {
    try {
      await runScheduledQuotaMessage(schedule);
    } catch (err) {
      console.error(
        `[quota:${sourceKey}] scheduled message ${schedule.id} failed: ${err.message}`,
      );
      markQuotaScheduleFailed(schedule.id, err.message);
    }
  }
}

const routeContext = {
  CLI,
  DEFAULT_AGENT,
  ENABLE_QUOTA_WATCH,
  HOST,
  LEGACY_SESSION_ID,
  MAX_DOWNLOAD_BYTES,
  MAX_PROMPT_BYTES,
  MAX_SESSIONS,
  MAX_UPLOAD_BYTES,
  PORT,
  PUBLIC_BASE_URL,
  TIMEOUT_MS,
  WEB_BUILD_DIR,
  activeRequests,
  agentPayload,
  agentRequiredError,
  agentRequiredOrUnknownError,
  agentTurnDependencies,
  bearerToken,
  broadcastScope,
  buildDiagnostics,
  buildUsageReport,
  cancelQuotaSchedule,
  clearHistory,
  purgeSession,
  createChatResponder,
  createChatSession,
  createQuotaSchedule,
  deleteChatSession,
  deleteRevokedTokenById,
  describeAgent,
  eventClients,
  eventWorkdir,
  fcm,
  finalizeStaleStreamingHistory,
  formatUptime,
  fs,
  getAgent,
  getDefaultWorkdir,
  getSettings,
  listAbsoluteDirectory,
  listAgents,
  listChatSessions,
  listQuotaSchedules,
  listTokenSummaries,
  markdownForConversation,
  inspectCodexAccount,
  normalizeDeviceId,
  notifyTaskCompletion,
  os,
  path,
  prepareDownload,
  prepareDownloadAbsolute,
  push,
  pushCategoriesFromBody,
  queryBool,
  randomUUID,
  readHistory,
  requestWorkdir,
  resolveAbsoluteUploadTarget,
  resolveAgentScope,
  resolveChatSession,
  resolveUploadTarget,
  revokeTokenById,
  runAgentTurn,
  runningScopes,
  safeDownloadName,
  scopeChains,
  scopeKeyFor,
  searchHistory,
  sendDirectoryZip,
  sendEvent,
  sendFilesystemError,
  sendWorkdirError,
  sessionContextKeyFor,
  sessionPayload,
  setActiveChatSession,
  setSettings,
  streamUploadToFile,
  terminalManager,
  touchChatSession,
  tokenRecordForToken,
  uploadedEntry,
  upsertHistoryMessage,
  validateWorkdir,
  workdirBusy,
  workdirPresence,
};

app.use(createMetaRouter(routeContext));
app.use(createPushRouter(routeContext));
app.use(createFsRouter(routeContext));
app.use(createChatRouter(routeContext));
app.use(createGroupRouter(routeContext));
app.use(createSessionsRouter(routeContext));
app.use(createQuotaRouter(routeContext));
app.use(createTerminalRouter(routeContext));

if (fs.existsSync(path.join(WEB_BUILD_DIR, 'index.html'))) {
  app.use(express.static(WEB_BUILD_DIR, {
    etag: true,
    lastModified: true,
    setHeaders(res, filePath) {
      const rel = path.relative(WEB_BUILD_DIR, filePath);
      // CanvasKit is pinned to the Flutter engine revision and is effectively
      // immutable between SDK upgrades; cache the wasm hard so it downloads
      // once and is then served from the browser cache with no request at all.
      if (rel.split(path.sep)[0] === 'canvaskit') {
        res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
        return;
      }
      // Other files (index.html, *.js, assets) keep their filenames across builds,
      // so allow caching but always revalidate: a matching ETag returns a tiny 304
      // instead of re-sending the bytes. Never `no-store` — that re-downloaded the
      // whole Web bundle on every load, which can make startup very slow.
      res.setHeader('Cache-Control', 'no-cache');
    },
  }));
  app.get('*', (req, res) => {
    if (req.path.startsWith('/api/')) {
      return res.status(404).json({ error: 'not found' });
    }
    res.setHeader('Cache-Control', 'no-cache');
    return res.sendFile(path.join(WEB_BUILD_DIR, 'index.html'));
  });
}

function flushHistoryForShutdown() {
  try {
    flushHistory();
  } catch (err) {
    console.error(`Failed to flush chat history: ${err.message}`);
  }
}

function exitCodeForSignal(signal) {
  return signal === 'SIGINT' ? 130 : 143;
}

process.on('exit', flushHistoryForShutdown);
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    terminalManager.closeAll();
    // Live agent sessions are children of this process; close them explicitly
    // so a restart never leaves orphaned CLI processes holding memory.
    shutdownPools().catch(() => {});
    flushHistoryForShutdown();
    process.exit(exitCodeForSignal(signal));
  });
}

const server = app.listen(PORT, HOST, () => {
  console.log(`Relay server listening on http://${HOST}:${PORT}`);
  // Warm the model-discovery cache off the request path. The first scan/spawn
  // per agent is synchronous, so priming it now keeps the first chat turn and
  // options fetch fast.
  setImmediate(() => {
    for (const agent of ['claude', 'codex']) {
      try {
        describeAgent(agent);
      } catch (_err) {
        // Best-effort; discovery falls back to the static catalog at call time.
      }
    }
  });
  if (PUBLIC_BASE_URL) {
    console.log(`public tunnel URL: ${PUBLIC_BASE_URL}`);
  }
  warnIfPlaintextTokenExposure();
  console.log(`default workdir: ${getDefaultWorkdir()}`);
  const staleHistoryCount = finalizeAllStaleStreamingHistory();
  if (staleHistoryCount > 0) {
    flushHistory();
    console.log(`finalized ${staleHistoryCount} stale streaming history item(s)`);
  }
  if (fs.existsSync(path.join(WEB_BUILD_DIR, 'index.html'))) {
    console.log(`serving Flutter web from ${WEB_BUILD_DIR}`);
  }
  if (!hasConfiguredToken()) {
    console.warn('No app token is configured. Create a credential before exposing this server.');
  }
  try {
    const recovered = reconcileRunningSchedules();
    if (recovered > 0) {
      console.warn(`Marked ${recovered} interrupted scheduled message(s) as failed.`);
    }
  } catch (err) {
    console.error(`Failed to reconcile scheduled messages: ${err.message}`);
  }
  if (ENABLE_QUOTA_WATCH) {
    startQuotaWatch({
      name: 'app',
      onReset: async (message, info) => {
        sendEvent('quota_reset', {
          message,
          messageZh: info && info.messageZh,
          info,
          createdAt: new Date().toISOString(),
        });
        // Reach offline clients; SSE only covers open app sessions.
        notifyAll({
          message,
          messageZh: info && info.messageZh,
          category: 'quota',
          // Matches the tag an open client uses for the event-stream copy, so a
          // browser that shows both collapses them into one notification.
          tag: 'quota',
        });
        processDueQuotaSchedules(info).catch((err) => {
          console.error(`[quota:${info && info.key}] scheduled message runner failed: ${err.message}`);
        });
      },
    });
  }
  if (ENABLE_CLAUDE_KEEPALIVE) {
    startClaudeQuotaKeepalive();
  }
});
terminalManager.attachServer(server);
