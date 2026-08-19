'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');

const CLAUDE_CREDS_PATH = path.join(os.homedir(), '.claude', '.credentials.json');
const CLAUDE_USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLAUDE_TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const CLAUDE_MESSAGES_URL = 'https://api.anthropic.com/v1/messages';
const CLAUDE_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const CLAUDE_OAUTH_BETA = 'oauth-2025-04-20';
const CLAUDE_API_VERSION = '2023-06-01';
// The keepalive ping is billed like any other Claude Code turn, so it uses a
// low-cost default model and the smallest possible completion. Deployments can
// override the model explicitly.
const CLAUDE_KEEPALIVE_MODEL =
  process.env.CLAUDE_KEEPALIVE_MODEL || 'claude-haiku-4-5';
const CLAUDE_CODE_SYSTEM_PROMPT =
  "You are Claude Code, Anthropic's official CLI for Claude.";

const CODEX_AUTH = path.join(os.homedir(), '.codex', 'auth.json');
const CODEX_CONFIG = path.join(os.homedir(), '.codex', 'config.toml');
const CODEX_URL = 'https://chatgpt.com/backend-api/codex/responses';
const CODEX_TOKEN_URL = 'https://auth.openai.com/oauth/token';
const CODEX_CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann';
const CODEX_CACHE_MS = 60_000;
const CLAUDE_CACHE_MS = 60_000;
const USAGE_CACHE_FILE = path.join(__dirname, '..', 'usage-cache.json');
const USAGE_BACKOFF_BASE_MS = parseInt(
  process.env.USAGE_BACKOFF_BASE_MS || '30000',
  10,
);
const USAGE_BACKOFF_MAX_MS = parseInt(
  process.env.USAGE_BACKOFF_MAX_MS || '900000',
  10,
);
// Hard timeout for every outbound usage/oauth request. Without it a stalled
// connection hangs /api/usage forever and permanently wedges the single-flight
// background refresh (its promise would never settle).
const USAGE_HTTP_TIMEOUT_MS = parseInt(
  process.env.USAGE_HTTP_TIMEOUT_MS || '15000',
  10,
);

function attachTimeout(req, url) {
  req.setTimeout(USAGE_HTTP_TIMEOUT_MS, () => {
    req.destroy(
      new UsageQueryError(
        `request to ${new URL(url).host} timed out after ${USAGE_HTTP_TIMEOUT_MS}ms`,
      ),
    );
  });
}

let codexCache = { at: 0, fetchedAt: '', value: null, stale: false };
let claudeCache = { at: 0, fetchedAt: '', value: null, stale: false };
let persistedUsageCache = null;
const usageBackoff = {
  claude: { until: 0, delayMs: 0, refreshPromise: null, credMtime: 0 },
  codex: { until: 0, delayMs: 0, refreshPromise: null, credMtime: 0 },
};

// Claude/Codex quota credentials are shared with the live CLIs, which rotate
// their OAuth tokens in place. A failed query is almost always a transient auth
// race the CLI fixes by rewriting its credential file, so we remember the file's
// mtime at failure time: once it changes, the backoff is dropped and the next
// query retries immediately with the fresh token instead of serving stale.
const USAGE_CRED_FILES = {
  claude: CLAUDE_CREDS_PATH,
  codex: CODEX_AUTH,
};

function credentialMtimeMs(key) {
  const file = USAGE_CRED_FILES[key];
  if (!file) return 0;
  try {
    return fs.statSync(file).mtimeMs;
  } catch (_err) {
    return 0;
  }
}

class UsageQueryError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

function loadUsageCache() {
  if (persistedUsageCache) return persistedUsageCache;
  try {
    const decoded = JSON.parse(fs.readFileSync(USAGE_CACHE_FILE, 'utf-8'));
    persistedUsageCache = decoded && typeof decoded === 'object' ? decoded : {};
  } catch (_err) {
    persistedUsageCache = {};
  }
  return persistedUsageCache;
}

function saveUsageCache() {
  const tmp = `${USAGE_CACHE_FILE}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(loadUsageCache(), null, 2)}\n`, {
    mode: 0o600,
  });
  fs.renameSync(tmp, USAGE_CACHE_FILE);
}

function persistedRecord(key) {
  const record = loadUsageCache()[key];
  if (!record || typeof record !== 'object' || !record.value) return null;
  return {
    fetchedAt: String(record.fetchedAt || record.savedAt || ''),
    value: record.value,
  };
}

function stripUsageMetadata(value) {
  const { fetchedAt: _fetchedAt, stale: _stale, ...clean } = value || {};
  return clean;
}

function withUsageMetadata(record, stale) {
  return {
    ...record.value,
    fetchedAt: record.fetchedAt,
    stale,
  };
}

function rememberUsageSuccess(key, value, setMemoryCache) {
  const fetchedAt = new Date().toISOString();
  const record = {
    fetchedAt,
    value: stripUsageMetadata(value),
  };
  loadUsageCache()[key] = record;
  saveUsageCache();
  setMemoryCache({
    at: Date.now(),
    fetchedAt,
    value: record.value,
    stale: false,
  });
  usageBackoff[key].delayMs = 0;
  usageBackoff[key].until = 0;
  return withUsageMetadata(record, false);
}

function rememberBackoff(key, err) {
  const state = usageBackoff[key];
  const previous = state.delayMs > 0 ? state.delayMs : USAGE_BACKOFF_BASE_MS / 2;
  const delayMs = Math.min(
    USAGE_BACKOFF_MAX_MS,
    Math.max(1000, previous * 2),
  );
  state.delayMs = delayMs;
  state.until = Date.now() + delayMs;
  state.credMtime = credentialMtimeMs(key);
  const status = err && err.status ? ` HTTP ${err.status}` : '';
  console.warn(
    `[usage:${key}] query failed${status}; backing off for ` +
      `${Math.round(delayMs / 1000)}s: ${err.message}`,
  );
}

function memoryRecord(cache) {
  if (!cache.value) return null;
  return {
    fetchedAt: cache.fetchedAt,
    value: cache.value,
  };
}

function fallbackRecord(key, cache) {
  return persistedRecord(key) || memoryRecord(cache);
}

function scheduleRefresh({ key, fetcher, setMemoryCache }) {
  const state = usageBackoff[key];
  if (state.refreshPromise) return;
  state.refreshPromise = (async () => {
    try {
      const value = await fetcher();
      rememberUsageSuccess(key, value, setMemoryCache);
    } catch (err) {
      rememberBackoff(key, err);
    } finally {
      state.refreshPromise = null;
    }
  })();
}

async function cachedUsage({
  key,
  ttlMs,
  getMemoryCache,
  setMemoryCache,
  fetcher,
}) {
  const now = Date.now();
  const cache = getMemoryCache();
  if (cache.value && !cache.stale && now - cache.at < ttlMs) {
    return withUsageMetadata(memoryRecord(cache), false);
  }

  const fallback = fallbackRecord(key, cache);
  if (!cache.value && fallback) {
    setMemoryCache({
      at: now,
      fetchedAt: fallback.fetchedAt,
      value: fallback.value,
      stale: true,
    });
    scheduleRefresh({ key, fetcher, setMemoryCache });
    return withUsageMetadata(fallback, true);
  }

  const state = usageBackoff[key];
  if (state.until > now && fallback) {
    // Still within the backoff window: only retry early if the CLI has rewritten
    // its credentials (token refreshed / re-login) since the failure. Otherwise
    // keep serving stale instead of hammering a still-failing API.
    if (credentialMtimeMs(key) <= state.credMtime) {
      return withUsageMetadata(fallback, true);
    }
    state.until = 0;
    state.delayMs = 0;
  }

  try {
    const value = await fetcher();
    return rememberUsageSuccess(key, value, setMemoryCache);
  } catch (err) {
    rememberBackoff(key, err);
    const latestFallback = fallbackRecord(key, getMemoryCache());
    if (latestFallback) return withUsageMetadata(latestFallback, true);
    throw err;
  }
}

function readClaudeCreds() {
  const raw = fs.readFileSync(CLAUDE_CREDS_PATH, 'utf-8');
  return JSON.parse(raw);
}

function httpJson(method, url, headers, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const opts = { method, headers: { ...headers } };
    if (data) {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(data);
    }
    const req = https.request(url, opts, (res) => {
      let buffer = '';
      res.on('data', (chunk) => {
        buffer += chunk;
      });
      res.on('end', () => {
        let parsed = null;
        try {
          parsed = JSON.parse(buffer);
        } catch (_err) {
          // Keep raw response.
        }
        resolve({ status: res.statusCode, body: parsed, raw: buffer });
      });
    });
    attachTimeout(req, url);
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function refreshClaudeToken() {
  const creds = readClaudeCreds();
  const oauth = creds.claudeAiOauth || {};
  if (!oauth.refreshToken) {
    throw new Error('Claude credentials are missing refreshToken. Run claude login again.');
  }

  const { status, body } = await httpJson('POST', CLAUDE_TOKEN_URL, {}, {
    grant_type: 'refresh_token',
    refresh_token: oauth.refreshToken,
    client_id: CLAUDE_CLIENT_ID,
  });

  if (status !== 200 || !body || !body.access_token) {
    throw new Error(`Failed to refresh Claude token (HTTP ${status}).`);
  }

  oauth.accessToken = body.access_token;
  if (body.refresh_token) oauth.refreshToken = body.refresh_token;
  if (body.expires_in) oauth.expiresAt = Date.now() + body.expires_in * 1000;
  creds.claudeAiOauth = oauth;

  const tmp = `${CLAUDE_CREDS_PATH}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(creds), { mode: 0o600 });
  fs.renameSync(tmp, CLAUDE_CREDS_PATH);
  return oauth.accessToken;
}

async function getValidClaudeToken() {
  const oauth = readClaudeCreds().claudeAiOauth || {};
  if (!oauth.accessToken) {
    throw new Error('Claude accessToken was not found. Run claude login.');
  }
  if (oauth.expiresAt && Date.now() > oauth.expiresAt - 60_000) {
    return refreshClaudeToken();
  }
  return oauth.accessToken;
}

async function callClaudeUsage(token) {
  return httpJson('GET', CLAUDE_USAGE_URL, {
    Authorization: `Bearer ${token}`,
    'anthropic-beta': CLAUDE_OAUTH_BETA,
    'User-Agent': 'claude-cli',
    Accept: 'application/json',
  });
}

async function fetchClaudeUsage() {
  let token = await getValidClaudeToken();
  let res = await callClaudeUsage(token);
  if (res.status === 401) {
    token = await refreshClaudeToken();
    res = await callClaudeUsage(token);
  }
  if (res.status !== 200 || !res.body) {
    throw new UsageQueryError(
      `Claude usage query failed (HTTP ${res.status}).`,
      res.status,
    );
  }
  return {
    data: res.body,
    subscriptionType: (readClaudeCreds().claudeAiOauth || {}).subscriptionType,
  };
}

async function getClaudeUsage() {
  return cachedUsage({
    key: 'claude',
    ttlMs: CLAUDE_CACHE_MS,
    getMemoryCache: () => claudeCache,
    setMemoryCache: (cache) => {
      claudeCache = cache;
    },
    fetcher: fetchClaudeUsage,
  });
}

// Claude's five-hour window only exists while it is running: once it lapses the
// usage API reports `resets_at: null` until the next real turn, which the app can
// only show as "unknown". Codex avoids that because its quota probe *is* a live
// request; Claude's is a plain read, so we send the equivalent minimal turn
// ourselves to restart the window. One token on the configured keepalive model,
// using the same OAuth credential and Claude Code identity as the usage query.
async function callClaudeMessages(token) {
  return httpJson('POST', CLAUDE_MESSAGES_URL, {
    Authorization: `Bearer ${token}`,
    'anthropic-beta': CLAUDE_OAUTH_BETA,
    'anthropic-version': CLAUDE_API_VERSION,
    'User-Agent': 'claude-cli',
    Accept: 'application/json',
  }, {
    model: CLAUDE_KEEPALIVE_MODEL,
    max_tokens: 1,
    system: [{ type: 'text', text: CLAUDE_CODE_SYSTEM_PROMPT }],
    messages: [{ role: 'user', content: 'hi' }],
  });
}

async function primeClaudeSession() {
  let token = await getValidClaudeToken();
  let res = await callClaudeMessages(token);
  if (res.status === 401) {
    token = await refreshClaudeToken();
    res = await callClaudeMessages(token);
  }
  // 429 means the quota is already exhausted, which is itself a running window:
  // the ping did its job and the caller should not treat it as a failure.
  if (res.status !== 200 && res.status !== 429) {
    const detail =
      (res.body && res.body.error && res.body.error.message) || res.raw || '';
    throw new UsageQueryError(
      `Claude keepalive request failed (HTTP ${res.status}). ${detail}`.trim(),
      res.status,
    );
  }
  return { status: res.status, model: CLAUDE_KEEPALIVE_MODEL };
}

// Drop the in-memory TTL for one source so the next read re-queries the API.
// Used after the keepalive ping so the fresh `resets_at` is picked up at once
// instead of after the normal cache window.
function invalidateUsageCache(key) {
  const caches = { claude: () => claudeCache, codex: () => codexCache };
  const cache = caches[key] && caches[key]();
  if (cache) cache.at = 0;
}

function httpHeadersOnly(url, headers, bodyStr) {
  return new Promise((resolve, reject) => {
    const opts = { method: 'POST', headers: { ...headers } };
    opts.headers['Content-Type'] = 'application/json';
    opts.headers['Content-Length'] = Buffer.byteLength(bodyStr);
    const req = https.request(url, opts, (res) => {
      const out = { status: res.statusCode, headers: res.headers };
      res.destroy();
      resolve(out);
    });
    attachTimeout(req, url);
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

function firstHeader(headers, key) {
  const value = headers[key];
  return Array.isArray(value) ? value[0] : value;
}

function readCodexModel() {
  try {
    const match = /^\s*model\s*=\s*"([^"]+)"/m.exec(
      fs.readFileSync(CODEX_CONFIG, 'utf-8'),
    );
    if (match) return match[1];
  } catch (_err) {
    // Use default.
  }
  return 'gpt-5.5';
}

// Codex shares ~/.codex/auth.json with the CLI. The access_token is short-lived,
// so when our quota probe sees a 401 we refresh it in place with the long-lived
// refresh_token (same OAuth flow the CLI uses) instead of forcing the user to go
// run a Codex message in a terminal. Mirrors refreshClaudeToken.
async function refreshCodexToken(auth) {
  const refreshToken = auth.tokens && auth.tokens.refresh_token;
  if (!refreshToken) {
    throw new Error('Codex credentials are missing refresh_token. Run codex login again.');
  }
  const { status, body } = await httpJson('POST', CODEX_TOKEN_URL, {}, {
    client_id: CODEX_CLIENT_ID,
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    scope: 'openid profile email',
  });
  if (status !== 200 || !body || !body.access_token) {
    throw new UsageQueryError(`Failed to refresh Codex token (HTTP ${status}).`, status);
  }
  auth.tokens = {
    ...auth.tokens,
    access_token: body.access_token,
    id_token: body.id_token || auth.tokens.id_token,
    refresh_token: body.refresh_token || refreshToken,
  };
  auth.last_refresh = new Date().toISOString();
  const tmp = `${CODEX_AUTH}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(auth, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, CODEX_AUTH);
  return auth.tokens.access_token;
}

function callCodexUsage(token, accountId, body) {
  return httpHeadersOnly(CODEX_URL, {
    Authorization: `Bearer ${token}`,
    'chatgpt-account-id': accountId,
    'OpenAI-Beta': 'responses=experimental',
    originator: 'codex_cli_rs',
    'User-Agent': 'codex_cli_rs/0.132.0',
    Accept: 'text/event-stream',
  }, body);
}

async function fetchCodexUsage() {
  const auth = JSON.parse(fs.readFileSync(CODEX_AUTH, 'utf-8'));
  let token = auth.tokens && auth.tokens.access_token;
  const accountId = (auth.tokens && auth.tokens.account_id) || '';
  if (!token) {
    throw new Error('Codex credentials were not found. Run codex login.');
  }

  const body = JSON.stringify({
    model: readCodexModel(),
    instructions: 'You are a helper.',
    input: [
      {
        type: 'message',
        role: 'user',
        content: [{ type: 'input_text', text: 'hi' }],
      },
    ],
    tools: [],
    tool_choice: 'auto',
    parallel_tool_calls: false,
    store: false,
    stream: true,
    include: [],
    reasoning: { effort: 'low' },
  });

  let { status, headers } = await callCodexUsage(token, accountId, body);
  if (status === 401) {
    token = await refreshCodexToken(auth);
    ({ status, headers } = await callCodexUsage(token, accountId, body));
  }
  const hasQuotaHeaders = Boolean(
    firstHeader(headers, 'x-codex-primary-used-percent') ||
      firstHeader(headers, 'x-codex-secondary-used-percent') ||
      firstHeader(headers, 'x-codex-primary-reset-at') ||
      firstHeader(headers, 'x-codex-secondary-reset-at'),
  );
  if (status !== 200 && !hasQuotaHeaders) {
    throw new UsageQueryError(`Codex usage query failed (HTTP ${status}).`, status);
  }

  const num = (key) => {
    const value = firstHeader(headers, key);
    return value == null || value === '' ? null : Number(value);
  };
  const iso = (key) => {
    const value = num(key);
    return value ? new Date(value * 1000).toISOString() : null;
  };
  const activeLimit = String(firstHeader(headers, 'x-codex-active-limit') || '');
  const primaryUsed = num('x-codex-primary-used-percent');
  const secondaryUsed = num('x-codex-secondary-used-percent');
  return {
    plan: firstHeader(headers, 'x-codex-plan-type') || activeLimit || 'Unknown',
    five_hour: {
      utilization:
        primaryUsed == null && status === 429 && (!activeLimit || activeLimit.includes('primary'))
          ? 100
          : primaryUsed,
      resets_at: iso('x-codex-primary-reset-at'),
    },
    seven_day: {
      utilization:
        secondaryUsed == null && status === 429 && activeLimit.includes('secondary')
          ? 100
          : secondaryUsed,
      resets_at: iso('x-codex-secondary-reset-at'),
    },
  };
}

async function getCodexUsage() {
  return cachedUsage({
    key: 'codex',
    ttlMs: CODEX_CACHE_MS,
    getMemoryCache: () => codexCache,
    setMemoryCache: (cache) => {
      codexCache = cache;
    },
    fetcher: fetchCodexUsage,
  });
}

function clampPercent(value) {
  if (value == null || !Number.isFinite(Number(value))) return null;
  return Math.max(0, Math.min(100, Number(value)));
}

function quotaItem(key, label, block) {
  const usedPercent = clampPercent(block && block.utilization);
  return {
    key,
    label,
    usedPercent,
    remainingPercent: usedPercent == null ? null : Math.max(0, 100 - usedPercent),
    resetsAt: (block && block.resets_at) || null,
    expired: false,
  };
}

// A stale cached quota whose reset time has already passed no longer reflects
// reality: the rolling window refreshed while the source was unreachable, so
// the cached utilization is meaningless — the real remaining is back near
// full. Flag those buckets `expired` so the client shows "window reset, awaiting
// refresh" instead of a misleading old percentage. Fresh (non-stale) data is
// never touched, even if its reset moment just passed, because it was just read.
function markExpiredQuotas(quotas, stale, nowMs = Date.now()) {
  if (!stale) return quotas;
  return quotas.map((quota) => {
    if (!quota || !quota.resetsAt) return quota;
    const resetMs = Date.parse(quota.resetsAt);
    if (Number.isFinite(resetMs) && resetMs <= nowMs) {
      return { ...quota, expired: true };
    }
    return quota;
  });
}

// Agents whose quota we can report. `normalize` maps each fetcher's own result
// shape onto a common { detail, asOf, stale, fiveHour, sevenDay } so the agent
// payload is built once below.
const USAGE_SOURCES = [
  {
    key: 'claude',
    label: 'Claude Code',
    fetch: getClaudeUsage,
    normalize: (r) => ({
      detail: r.subscriptionType || '',
      asOf: r.fetchedAt || null,
      stale: !!r.stale,
      fiveHour: r.data.five_hour,
      sevenDay: r.data.seven_day,
    }),
  },
  {
    key: 'codex',
    label: 'Codex',
    fetch: getCodexUsage,
    normalize: (r) => ({
      detail: r.plan || '',
      asOf: r.fetchedAt || null,
      stale: !!r.stale,
      fiveHour: r.five_hour,
      sevenDay: r.seven_day,
    }),
  },
];

async function buildAgentUsage({ key, label, fetch, normalize, unavailable }) {
  if (unavailable) {
    return { key, label, available: false, unavailableReason: unavailable, quotas: [] };
  }
  try {
    const { detail, asOf, stale, fiveHour, sevenDay } = normalize(await fetch());
    return {
      key,
      label,
      available: true,
      detail,
      asOf,
      stale,
      quotas: markExpiredQuotas(
        [
          quotaItem('five_hour', '5 hour quota', fiveHour),
          quotaItem('seven_day', 'Weekly quota', sevenDay),
        ],
        stale,
      ),
    };
  } catch (err) {
    return { key, label, available: true, error: err.message, quotas: [] };
  }
}

async function buildUsageReport() {
  // The fetched sources are independent network round-trips; run them together so
  // the dialog waits for the slower one, not the sum of all of them.
  const agents = await Promise.all(USAGE_SOURCES.map(buildAgentUsage));

  return {
    createdAt: new Date().toISOString(),
    mode: 'remaining',
    hasStale: agents.some((agent) => agent.stale === true),
    agents,
  };
}

module.exports = {
  getClaudeUsage,
  getCodexUsage,
  invalidateUsageCache,
  markExpiredQuotas,
  primeClaudeSession,
  buildUsageReport,
};
