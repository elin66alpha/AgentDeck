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

// Expiry claim of a JWT, in epoch milliseconds. The payload is decoded, never
// verified: only `exp` is read and no token value leaves this module.
function jwtExpiresAt(token) {
  const payload = String(token || '').split('.')[1];
  if (!payload) return null;
  try {
    const claims = JSON.parse(
      Buffer.from(payload, 'base64url').toString('utf8'),
    );
    return Number.isFinite(claims.exp) ? claims.exp * 1000 : null;
  } catch (_err) {
    return null;
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

function codexCredential(fsModule, homeDir) {
  const auth = readJson(fsModule, path.join(homeDir, '.codex', 'auth.json'));
  const tokens = (auth && auth.tokens) || {};
  return {
    authed: nonEmpty(tokens.access_token),
    // The id_token carries the session expiry the user actually has to renew by
    // logging in again; the access token is rotated on its own far more often.
    expiresAt: jwtExpiresAt(tokens.id_token),
  };
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

// Login state plus, for the OAuth agents, when the stored credential runs out.
// `expiresAt` is null whenever the agent has no such timestamp on disk, which is
// the case for every host-managed API key.
function agentCredential(agentKey, installed, fsModule, homeDir) {
  switch (agentKey) {
    case 'claude':
      return claudeCredential(fsModule, homeDir);
    case 'codex':
      return codexCredential(fsModule, homeDir);
    case 'hermes':
      return { authed: hermesAuthed(fsModule, homeDir), expiresAt: null };
    case 'opencode':
      return { authed: installed, expiresAt: null };
    default:
      return { authed: false, expiresAt: null };
  }
}

function buildStatuses({ fsModule, homeDir, commandExistsFn }) {
  const statuses = {};
  for (const agent of Object.values(AGENTS)) {
    const installed = commandExistsFn(agent.bin || agent.key);
    const credential = agentCredential(agent.key, installed, fsModule, homeDir);
    statuses[agent.key] = {
      installed,
      authed: credential.authed,
      authKind: AUTH_KIND[agent.key] || 'unknown',
      credentialExpiresAt: credential.expiresAt,
    };
  }
  return statuses;
}

function getAgentStatuses(options = {}) {
  const fsModule = options.fs || fs;
  const homeDir = options.homeDir || os.homedir();
  const commandExistsFn = options.commandExists || commandExists;
  const now = typeof options.now === 'function' ? options.now() : Date.now();
  const useCache = options.cache !== false;
  const cacheKey = homeDir;
  if (useCache) {
    const cached = statusCache.get(cacheKey);
    if (cached && now - cached.at < STATUS_TTL_MS) {
      return cached.value;
    }
  }
  const value = buildStatuses({ fsModule, homeDir, commandExistsFn });
  if (useCache) statusCache.set(cacheKey, { value, at: now });
  return value;
}

function clearAgentStatusCache() {
  statusCache.clear();
}

module.exports = {
  getAgentStatuses,
  clearAgentStatusCache,
};
