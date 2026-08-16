'use strict';

const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  clearAgentStatusCache,
  getAgentStatuses,
} = require('../lib/agent-status');

const scratchDirs = [];

function makeHome() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-agent-status-'));
  scratchDirs.push(dir);
  return dir;
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value));
}

function writeText(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, value);
}

function statuses(homeDir, installedBins, options = {}) {
  return getAgentStatuses({
    homeDir,
    cache: false,
    commandExists: (bin) => installedBins.has(bin),
    ...options,
  });
}

after(() => {
  clearAgentStatusCache();
  for (const dir of scratchDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// A JWT with only the `exp` claim, which is all the status reader decodes.
function jwt(expSeconds) {
  const payload = Buffer.from(JSON.stringify({ exp: expSeconds })).toString(
    'base64url',
  );
  return `header.${payload}.signature`;
}

test('detects installed CLI agents and credential files without exposing values', () => {
  const home = makeHome();
  writeJson(path.join(home, '.claude', '.credentials.json'), {
    claudeAiOauth: {
      accessToken: 'access-value',
      refreshToken: 'refresh-value',
    },
  });
  writeJson(path.join(home, '.codex', 'auth.json'), {
    tokens: { access_token: 'codex-token' },
  });
  writeJson(path.join(home, '.hermes', 'auth.json'), {
    provider: 'openai',
    apiKey: 'hermes-key',
  });

  const result = statuses(
    home,
    new Set(['claude', 'codex', 'opencode', 'hermes']),
  );

  assert.deepEqual(result.claude, {
    installed: true,
    authed: true,
    authKind: 'oauth',
    credentialExpiresAt: null,
  });
  assert.deepEqual(result.codex, {
    installed: true,
    authed: true,
    authKind: 'oauth',
    credentialExpiresAt: null,
  });
  assert.deepEqual(result.hermes, {
    installed: true,
    authed: true,
    authKind: 'apiKey',
    credentialExpiresAt: null,
  });
  assert.deepEqual(result.opencode, {
    installed: true,
    authed: true,
    authKind: 'apiKeyOptional',
    credentialExpiresAt: null,
  });
});

test('reports the OAuth credential expiry for claude and codex', () => {
  const home = makeHome();
  writeJson(path.join(home, '.claude', '.credentials.json'), {
    claudeAiOauth: {
      accessToken: 'access-value',
      refreshToken: 'refresh-value',
      expiresAt: 1893456000000,
    },
  });
  writeJson(path.join(home, '.codex', 'auth.json'), {
    tokens: { access_token: 'codex-token', id_token: jwt(1893456789) },
  });

  const result = statuses(home, new Set(['claude', 'codex']));

  assert.equal(result.claude.credentialExpiresAt, 1893456000000);
  assert.equal(result.codex.credentialExpiresAt, 1893456789000);
});

test('reports a null expiry when the credential carries no usable timestamp', () => {
  const home = makeHome();
  writeJson(path.join(home, '.claude', '.credentials.json'), {
    claudeAiOauth: {
      accessToken: 'access-value',
      refreshToken: 'refresh-value',
      expiresAt: 'not-a-number',
    },
  });
  writeJson(path.join(home, '.codex', 'auth.json'), {
    tokens: { access_token: 'codex-token', id_token: 'not-a-jwt' },
  });

  const result = statuses(home, new Set(['claude', 'codex']));

  assert.equal(result.claude.authed, true);
  assert.equal(result.claude.credentialExpiresAt, null);
  assert.equal(result.codex.authed, true);
  assert.equal(result.codex.credentialExpiresAt, null);
});

test('requires the expected credential shape for each agent', () => {
  const home = makeHome();
  writeJson(path.join(home, '.claude', '.credentials.json'), {
    claudeAiOauth: { accessToken: 'access-only' },
  });
  writeJson(path.join(home, '.codex', 'auth.json'), {
    tokens: {},
  });
  writeJson(path.join(home, '.hermes', 'auth.json'), {
    provider: 'openai',
  });

  const result = statuses(
    home,
    new Set(['claude', 'codex', 'opencode', 'hermes']),
  );

  assert.equal(result.claude.authed, false);
  assert.equal(result.codex.authed, false);
  assert.equal(result.hermes.authed, false);
  assert.equal(result.opencode.authed, true);
});

test('detects hermes provider and API key in config yaml', () => {
  const home = makeHome();
  writeText(
    path.join(home, '.hermes', 'config.yaml'),
    'provider: openai\napi_key: sk-test\n',
  );

  const result = statuses(home, new Set(['hermes']));

  assert.equal(result.hermes.installed, true);
  assert.equal(result.hermes.authed, true);
});

test('caches status detection briefly', () => {
  const home = makeHome();
  let installed = true;
  const commandExists = () => installed;

  clearAgentStatusCache();
  const first = getAgentStatuses({
    homeDir: home,
    commandExists,
    now: () => 1000,
  });
  installed = false;
  const cached = getAgentStatuses({
    homeDir: home,
    commandExists,
    now: () => 2000,
  });
  const expired = getAgentStatuses({
    homeDir: home,
    commandExists,
    now: () => 62000,
  });

  assert.equal(first.claude.installed, true);
  assert.equal(cached.claude.installed, true);
  assert.equal(expired.claude.installed, false);
});
