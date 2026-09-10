'use strict';

const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');
const express = require('express');

const createMetaRouter = require('../routes/meta');

let server;
let base;
let accountChecks = 0;
let nextAccountError = null;

before(async () => {
  const app = express();
  app.use(
    createMetaRouter({
      DEFAULT_AGENT: 'claude',
      getAgentStatuses: () => ({
        claude: {
          installed: true,
          authed: true,
          authKind: 'oauth',
          credentialExpiresAt: 1893456000000,
        },
        codex: {
          installed: true,
          authed: false,
          authKind: 'oauth',
          credentialExpiresAt: 1893456789000,
        },
        opencode: {
          installed: true,
          authed: true,
          authKind: 'apiKeyOptional',
        },
        hermes: { installed: true, authed: false, authKind: 'apiKey' },
      }),
      listAgents: () => [
        { key: 'claude', label: 'Claude Code', description: 'Claude CLI' },
        { key: 'codex', label: 'Codex', description: 'Codex CLI' },
        { key: 'opencode', label: 'OpenCode', description: 'OpenCode CLI' },
        { key: 'hermes', label: 'Hermes', description: 'Hermes CLI' },
      ],
      inspectCodexAccount: async ({ refreshToken }) => {
        accountChecks += 1;
        assert.equal(refreshToken, true);
        if (nextAccountError) {
          const err = nextAccountError;
          nextAccountError = null;
          throw err;
        }
        return {
          account: {
            type: 'apiKey',
            email: 'must-not-reach-the-client@example.invalid',
          },
          requiresOpenaiAuth: true,
        };
      },
    }),
  );
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
});

after(() => {
  if (server) server.close();
});

test('/api/agents returns every agent with install/auth usability fields', async () => {
  const response = await fetch(`${base}/api/agents`);
  assert.equal(response.status, 200);
  const body = await response.json();

  assert.equal(body.defaultAgent, 'claude');
  assert.deepEqual(
    body.agents.map((agent) => agent.key),
    ['claude', 'codex', 'opencode', 'hermes'],
  );

  const byKey = Object.fromEntries(
    body.agents.map((agent) => [agent.key, agent]),
  );
  assert.deepEqual(
    {
      key: byKey.claude.key,
      label: byKey.claude.label,
      description: byKey.claude.description,
      installed: byKey.claude.installed,
      authed: byKey.claude.authed,
      authKind: byKey.claude.authKind,
      usable: byKey.claude.usable,
      credentialExpiresAt: byKey.claude.credentialExpiresAt,
    },
    {
      key: 'claude',
      label: 'Claude Code',
      description: 'Claude CLI',
      installed: true,
      authed: true,
      authKind: 'oauth',
      usable: true,
      credentialExpiresAt: 1893456000000,
    },
  );
  assert.equal(byKey.codex.usable, false);
  assert.equal(byKey.codex.credentialExpiresAt, null);
  assert.equal(byKey.opencode.credentialExpiresAt, null);
  assert.equal(byKey.opencode.usable, true);
  assert.equal(byKey.hermes.authKind, 'apiKey');
  // hermes is managed out-of-band, so it is usable once installed even with no
  // key Relay can see.
  assert.equal(byKey.hermes.usable, true);
  assert.equal(accountChecks, 0);
});

test('/api/agents can verify Codex credentials through account/read', async () => {
  const response = await fetch(`${base}/api/agents?verifyCredentials=true`);
  assert.equal(response.status, 200);
  const body = await response.json();
  const codex = body.agents.find((agent) => agent.key === 'codex');

  assert.equal(codex.authed, true);
  assert.equal(codex.usable, true);
  assert.equal(codex.authKind, 'apiKey');
  assert.equal(codex.credentialExpiresAt, null);
  assert.equal(JSON.stringify(codex).includes('must-not-reach'), false);
  assert.equal(accountChecks, 1);
});

test('/api/auth/status uses the same forced Codex verification', async () => {
  const response = await fetch(
    `${base}/api/auth/status?verifyCredentials=true`,
  );
  assert.equal(response.status, 200);
  const body = await response.json();
  const codex = body.agents.find((agent) => agent.key === 'codex');
  assert.equal(codex.loggedIn, true);
  assert.equal(accountChecks, 2);
});

test('a rejected refresh is reported as requiring login', async () => {
  nextAccountError = new Error(
    'OAuth refresh token was rejected: refresh_token_expired',
  );
  const response = await fetch(`${base}/api/agents?verifyCredentials=true`);
  assert.equal(response.status, 200);
  const body = await response.json();
  const codex = body.agents.find((agent) => agent.key === 'codex');
  assert.equal(codex.authed, false);
  assert.equal(codex.usable, false);
  assert.equal(accountChecks, 3);
});

test('a transient verification failure is not misreported as logout', async () => {
  nextAccountError = new Error('connect ETIMEDOUT');
  const response = await fetch(`${base}/api/agents?verifyCredentials=true`);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: 'Codex credential verification failed. Try again.',
  });
  assert.equal(accountChecks, 4);
});
