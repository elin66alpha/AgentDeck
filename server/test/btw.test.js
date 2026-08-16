'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const createBtwRouter = require('../routes/btw');

// Deterministic scope-key shape so tests can assert exact keys.
const scopeKeyFor = (agentKey, workdir, sessionId) =>
  `${agentKey}|${workdir}|${sessionId}`;

// A minimal Express-style response that records status/json.
function fakeResponse() {
  return {
    statusCode: 200,
    jsonBody: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.jsonBody = body;
      return this;
    },
  };
}

// Pull a single route handler out of the router's layer stack.
function handlerFor(router, method, path) {
  const layer = router.stack.find(
    (l) => l.route && l.route.path === path && l.route.methods[method],
  );
  if (!layer) throw new Error(`no ${method} ${path} route`);
  return layer.route.stack[0].handle;
}

// Builds a ctx whose resolveAgentScope canonicalizes the requested session id to
// a *different* id, so a route that keys off the raw request id (the old bug)
// would target a different scope than resolveAgentScope produced.
function makeCtx(overrides = {}) {
  const cleared = { sessions: [], histories: [], purged: [] };
  const reads = [];
  const finalized = [];
  const ctx = {
    runningScopes: overrides.runningScopes || new Set(),
    scopeChains: overrides.scopeChains || new Map(),
    scopeKeyFor,
    resolveAgentScope: (req, res, { agentKey }) => ({
      agent: { key: agentKey },
      workdir: '/repo',
      contextKey: `ctx:${agentKey}:/repo`,
      // Canonical id differs from whatever the client requested.
      session: { id: 'sess-canonical' },
      scopeKey: scopeKeyFor(agentKey, '/repo', 'sess-canonical'),
    }),
    MAX_PROMPT_BYTES: 1024 * 1024,
    activeRequests: new Map(),
    agentTurnDependencies: () => ({
      runAgent() {
        throw new Error('base runAgent should not be called by /api/btw');
      },
    }),
    createChatResponder: () => ({}),
    purgeSession: async (key, options) => {
      cleared.sessions.push(key);
      cleared.purged.push(options);
      return true;
    },
    clearHistory: (key) => {
      cleared.histories.push(key);
    },
    finalizeStaleStreamingHistory: (key) => finalized.push(key),
    normalizeDeviceId: () => 'device-test',
    randomUUID: () => 'request-generated',
    readHistory: (key) => {
      reads.push(key);
      return [];
    },
    runAgentTurn: async () => {},
    runBtwAgent() {
      throw new Error('runBtwAgent was not stubbed');
    },
    sessionPayload: (session) => session,
    ...overrides.ctx,
  };
  return { ctx, cleared, reads, finalized };
}

test('btw clear targets the canonical session scope, not the raw requested id', async () => {
  const { ctx, cleared } = makeCtx();
  const router = createBtwRouter(ctx);
  const clear = handlerFor(router, 'post', '/api/btw/clear');

  const res = fakeResponse();
  // Client sends a session id that resolveAgentScope canonicalizes differently.
  await clear({ body: { agent: 'claude', sessionId: 'sess-requested' } }, res);

  assert.equal(res.jsonBody.ok, true);
  const expectedKey = scopeKeyFor('btw:claude', '/repo', 'sess-canonical');
  assert.deepEqual(cleared.sessions, [expectedKey]);
  assert.deepEqual(cleared.histories, [expectedKey]);
  // Regression guard: never key off the raw request id.
  assert.ok(
    !cleared.sessions.some((k) => k.includes('sess-requested')),
    'clear must not use the raw requested session id',
  );
});

test('btw clear and history resolve to the same side-chat scope key', async () => {
  const { ctx, cleared, reads } = makeCtx();
  const router = createBtwRouter(ctx);
  const clear = handlerFor(router, 'post', '/api/btw/clear');
  const history = handlerFor(router, 'get', '/api/btw/history');

  await clear({ body: { agent: 'claude', sessionId: 'sess-requested' } }, fakeResponse());
  await history(
    { query: { agent: 'claude', sessionId: 'sess-requested' } },
    fakeResponse(),
  );

  // The key history read from must equal the key clear wiped.
  assert.equal(cleared.sessions.length, 1);
  assert.equal(reads.length, 1);
  assert.equal(reads[0], cleared.sessions[0]);
});

test('btw clear uses an agent-specific side scope for codex', async () => {
  const { ctx, cleared } = makeCtx();
  const router = createBtwRouter(ctx);
  const clear = handlerFor(router, 'post', '/api/btw/clear');

  const res = fakeResponse();
  await clear({ body: { agent: 'codex', sessionId: 'sess-requested' } }, res);

  assert.equal(res.jsonBody.ok, true);
  assert.deepEqual(cleared.sessions, [
    scopeKeyFor('btw:codex', '/repo', 'sess-canonical'),
  ]);
});

test('btw post uses the native agent side runner for codex without transcript seeding', async () => {
  const calls = [];
  const { ctx } = makeCtx({
    ctx: {
      runBtwAgent: (agentKey, prompt, _onEvent, options) => {
        calls.push({ agentKey, prompt, options });
        return 'side answer';
      },
      runAgentTurn: async (options) => {
        await options.dependencies.runAgent(
          options.agentKey,
          options.prompt,
          () => {},
          {
            sessionKey: options.scopeKey,
            signal: options.signal,
            workdir: options.workdir,
            settings: { permission: 'workspace-write' },
          },
        );
      },
    },
  });
  const router = createBtwRouter(ctx);
  const post = handlerFor(router, 'post', '/api/btw');

  await post(
    {
      body: {
        agent: 'codex',
        prompt: 'what did the main task decide?',
        requestId: 'req-1',
        sessionId: 'sess-requested',
      },
      get: () => '',
    },
    fakeResponse(),
  );

  assert.equal(calls.length, 1);
  assert.equal(calls[0].agentKey, 'codex');
  assert.equal(calls[0].prompt, 'what did the main task decide?');
  assert.equal(
    calls[0].options.mainSessionKey,
    scopeKeyFor('codex', '/repo', 'sess-canonical'),
  );
  assert.equal(
    calls[0].options.btwSessionKey,
    scopeKeyFor('btw:codex', '/repo', 'sess-canonical'),
  );
  assert.equal(calls[0].options.settings.permission, 'workspace-write');
  assert.ok(
    !calls[0].prompt.includes('Main chat transcript'),
    'Codex BTW must not be seeded with a Relay transcript prompt',
  );
});

test('btw clear refuses while a side question is running', async () => {
  const runningScopes = new Set([
    scopeKeyFor('btw:claude', '/repo', 'sess-canonical'),
  ]);
  const { ctx, cleared } = makeCtx({ runningScopes });
  const router = createBtwRouter(ctx);
  const clear = handlerFor(router, 'post', '/api/btw/clear');

  const res = fakeResponse();
  await clear({ body: { agent: 'claude', sessionId: 'sess-requested' } }, res);

  assert.equal(res.statusCode, 409);
  assert.equal(res.jsonBody.code, 'SESSION_BUSY');
  assert.deepEqual(cleared.sessions, [], 'nothing cleared while running');
});

test('btw clear rejects unsupported agents before touching any scope', async () => {
  const { ctx, cleared } = makeCtx();
  const router = createBtwRouter(ctx);
  const clear = handlerFor(router, 'post', '/api/btw/clear');

  const res = fakeResponse();
  await clear({ body: { agent: 'opencode', sessionId: 'sess-requested' } }, res);

  assert.equal(res.statusCode, 400);
  assert.equal(res.jsonBody.code, 'BTW_UNSUPPORTED');
  assert.deepEqual(cleared.sessions, []);
});
