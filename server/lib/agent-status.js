'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const { AGENTS, commandExists } = require('./agents');

const STATUS_TTL_MS = 60 * 1000;
const statusCache = new Map();

const AUTH_KIND = {
  claude: 'oauth',
  codex: 'oauth',
  hermes: 'apiKey',
  opencode: 'apiKeyOptional',
};

function readJson(fsModule, filePath) {
  try {
    return JSON.parse(fsModule.readFileSync(filePath, 'utf8'));
  } catch (_err) {
    return null;
  }
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function fileHasText(fsModule, filePath) {
  try {
    return fsModule.readFileSync(filePath, 'utf8').trim().length > 0;
  } catch (_err) {
    return false;
  }
}

function expiryOrNull(value) {
  return Number.isFinite(value) && value > 0 ? value : null;
}

function claudeCredential(fsModule, homeDir) {
  const creds = readJson(
    fsModule,
    path.join(homeDir, '.claude', '.credentials.json'),
  );
  const oauth = (creds && creds.claudeAiOauth) || {};
  return {
    authed: nonEmpty(oauth.accessToken) && nonEmpty(oauth.refreshToken),
    expiresAt: expiryOrNull(oauth.expiresAt),
  };
}

function normalizedAuthMode(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[_-]/g, '');
}

function codexCredential(fsModule, homeDir, environment) {
  const auth = readJson(fsModule, path.join(homeDir, '.codex', 'auth.json')) || {};
  const tokens = (auth && auth.tokens) || {};
  const mode = normalizedAuthMode(auth.auth_mode);
  const hasApiKey =
    nonEmpty(auth.OPENAI_API_KEY) || nonEmpty(environment.OPENAI_API_KEY);

  // `auth_mode` is authoritative when present. Keep a shape-based fallback for
  // older Codex versions, which wrote the same values without the discriminator.
  if (mode === 'apikey' || (!mode && hasApiKey)) {
    return {
      authed: hasApiKey,
      authKind: 'apiKey',
      expiresAt: null,
    };
  }
  if (mode.includes('bedrock')) {
    return { authed: true, authKind: 'hostManaged', expiresAt: null };
  }
  const managedChatGpt = mode === 'chatgpt';
  return {
    authed: managedChatGpt
      ? nonEmpty(tokens.access_token) && nonEmpty(tokens.refresh_token)
      : nonEmpty(tokens.access_token),
    authKind: 'oauth',
    // Codex rotates its short-lived ID/access tokens automatically. Its opaque
    // refresh token has no client-readable expiry, so there is no honest login
    // countdown to report here.
    expiresAt: null,
  };
}

// Convert the non-secret part of Codex `account/read` into Relay's status
// vocabulary. Email, account ids and every credential value are intentionally
// discarded. `requiresOpenaiAuth` describes the provider, not login state: an
// account object is what proves configured auth, while false means the active
// provider can run without OpenAI credentials.
function codexAccountCredential(result, fallback = {}) {
  const account = result && typeof result.account === 'object' ? result.account : null;
  if (!account) {
    return {
      ...fallback,
      authed: result && result.requiresOpenaiAuth === false,
      authKind:
        result && result.requiresOpenaiAuth === false
          ? 'hostManaged'
          : fallback.authKind || 'oauth',
      credentialExpiresAt: null,
    };
  }

  const type = normalizedAuthMode(account.type);
  let authKind = 'hostManaged';
  if (type === 'apikey') authKind = 'apiKey';
  else if (type === 'chatgpt' || type === 'chatgptauthtokens') authKind = 'oauth';

  return {
    ...fallback,
    authed: true,
    authKind,
    credentialExpiresAt: null,
  };
}

function isCodexReauthError(err) {
  const text = `${(err && err.message) || ''} ${JSON.stringify(
    (err && err.data) || '',
  )}`;
  return /(?:refresh token.*(?:rejected|expired|invalid|revoked)|invalid_grant|not logged in|re-?authentication required|login required)/i.test(
    text,
  );
}

function hasApiKeyLikeValue(value, keyName = '') {
  if (value === null || value === undefined) return false;
  if (Array.isArray(value)) {
    return value.some((item) => hasApiKeyLikeValue(item, keyName));
  }
  if (typeof value === 'object') {
    return Object.entries(value).some(([key, child]) =>
      hasApiKeyLikeValue(child, key),
    );
  }
  if (!nonEmpty(value)) return false;
  return /(?:api[_-]?key|access[_-]?token|auth[_-]?token|token|key)$/i.test(
    keyName,
  );
}

function hermesConfigAuthed(fsModule, homeDir) {
  let text = '';
  try {
    text = fsModule.readFileSync(
      path.join(homeDir, '.hermes', 'config.yaml'),
      'utf8',
    );
  } catch (_err) {
    return false;
  }
  const hasProvider = /^\s*provider\s*:\s*['"]?[^'"\s#][^#\n]*$/im.test(text);
  const hasKey =
    /^\s*(?:api[_-]?key|apiKey|key|token)\s*:\s*['"]?[^'"\s#][^#\n]*$/im.test(
      text,
    );
  return hasProvider && hasKey;
}

function hermesAuthed(fsModule, homeDir) {
  const auth = readJson(fsModule, path.join(homeDir, '.hermes', 'auth.json'));
  return hasApiKeyLikeValue(auth) || hermesConfigAuthed(fsModule, homeDir);
}

// Login state plus a real stored deadline when one exists. `expiresAt` is null
// for Codex's rotating managed tokens and every host-managed API key.
function agentCredential(agentKey, installed, fsModule, homeDir, environment) {
  switch (agentKey) {
    case 'claude':
      return claudeCredential(fsModule, homeDir);
    case 'codex':
      return codexCredential(fsModule, homeDir, environment);
    case 'hermes':
      return { authed: hermesAuthed(fsModule, homeDir), expiresAt: null };
    case 'opencode':
      return { authed: installed, expiresAt: null };
    default:
      return { authed: false, expiresAt: null };
  }
}

function buildStatuses({ fsModule, homeDir, commandExistsFn, environment }) {
  const statuses = {};
  for (const agent of Object.values(AGENTS)) {
    const installed = commandExistsFn(agent.bin || agent.key);
    const credential = agentCredential(
      agent.key,
      installed,
      fsModule,
      homeDir,
      environment,
    );
    statuses[agent.key] = {
      installed,
      authed: credential.authed,
      authKind: credential.authKind || AUTH_KIND[agent.key] || 'unknown',
      credentialExpiresAt: credential.expiresAt,
    };
  }
  return statuses;
}

function getAgentStatuses(options = {}) {
  const fsModule = options.fs || fs;
  const homeDir = options.homeDir || os.homedir();
  const environment = options.env || process.env;
  const commandExistsFn = options.commandExists || commandExists;
  const now = typeof options.now === 'function' ? options.now() : Date.now();
  const useCache = options.cache !== false;
  const cacheKey = homeDir;
  if (useCache && options.refresh !== true) {
    const cached = statusCache.get(cacheKey);
    if (cached && now - cached.at < STATUS_TTL_MS) {
      return cached.value;
    }
  }
  const value = buildStatuses({
    fsModule,
    homeDir,
    commandExistsFn,
    environment,
  });
  if (useCache) statusCache.set(cacheKey, { value, at: now });
  return value;
}

function clearAgentStatusCache() {
  statusCache.clear();
}

module.exports = {
  getAgentStatuses,
  clearAgentStatusCache,
  codexAccountCredential,
  isCodexReauthError,
};
