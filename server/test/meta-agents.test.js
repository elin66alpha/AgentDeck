'use strict';

const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');
const express = require('express');

const createMetaRouter = require('../routes/meta');

let server;
let base;

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
          credentialExpiresAt: null,
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
});
