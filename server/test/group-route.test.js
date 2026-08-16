'use strict';

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const express = require('express');

// Isolate the on-disk state for groups + history before requiring the modules.
const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-group-route-'));
process.env.RELAY_GROUPS_FILE = path.join(scratchDir, 'groups.json');
process.env.RELAY_HISTORY_FILE = path.join(scratchDir, 'history.json');

const history = require('../lib/history');
const { sessionScopeKey } = require('../lib/chat-sessions');
const { runAgentTurn } = require('../lib/agent-turn');
const { normalizeSettings } = require('../lib/agent-options');
const createGroupRouter = require('../routes/group');

const SEP = '\0';
const WORKDIR = '/tmp/group-int';
const AGENTS = {
  claude: { key: 'claude', label: 'Claude Code', run: () => {} },
  codex: { key: 'codex', label: 'Codex', run: () => {} },
};

// Calls into the fake CLI runner, so the test can assert the per-member session
// key and the delta-built prompt each member actually received.
const runCalls = [];
// Events broadcast on the shared stream, so the test can assert the round's
// lifecycle signals (group_message, group_done) reach other devices.
const sentEvents = [];

function buildContext() {
  const sessionContextKeyFor = (agentKey, workdir) => `${workdir}${SEP}${agentKey}`;
  const scopeKeyFor = (agentKey, workdir, sessionId) =>
    sessionScopeKey(sessionContextKeyFor(agentKey, workdir), sessionId);
  const runningScopes = new Set();
  const scopeChains = new Map();

  // The shared dependencies the real runAgentTurn needs; the route overrides
  // runAgent (member session key) and broadcastScope (groupId tag) on top.
  const agentTurnDependencies = () => ({
    broadcastScope: () => {},
    enqueueScope: (_key, fn) => fn(),
    getSettings: () => ({}),
    runningScopes,
    scopeChains,
    touchChatSession: () => {},
    updateHistoryMessage: history.updateHistoryMessage,
    upsertHistoryMessage: history.upsertHistoryMessage,
    async runAgent(agentKey, prompt, onEvent, opts) {
      runCalls.push({
        agentKey,
        prompt,
        sessionKey: opts.sessionKey,
        workdir: opts.workdir,
        settings: opts.settings,
      });
      onEvent({ type: 'delta', text: `reply from ${agentKey}` });
      return `reply from ${agentKey}`;
    },
  });

  return {
    MAX_PROMPT_BYTES: 100 * 1024,
    activeRequests: new Map(),
    agentTurnDependencies,
    clearHistory: history.clearHistory,
    purgeSession: async () => true,
    finalizeStaleStreamingHistory: history.finalizeStaleStreamingHistory,
    getAgent: (key) => AGENTS[key] || null,
    normalizeDeviceId: () => '',
    notifyTaskCompletion: () => {},
    randomUUID: crypto.randomUUID,
    readHistory: history.readHistory,
    requestWorkdir: (req) => req.get('x-workdir') || WORKDIR,
    runAgentTurn,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sendEvent: (type, payload) => sentEvents.push({ type, payload }),
    sendWorkdirError: (res, err) => res.status(400).json({ error: err.message }),
    sessionContextKeyFor,
    upsertHistoryMessage: history.upsertHistoryMessage,
    // The real resolver canonicalizes + checks the path exists; the route only
    // needs the resolved dir, so echo it back for the test.
    validateWorkdir: (value) => ({ dir: String(value), created: false }),
  };
}

let server;
let base;

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(createGroupRouter(buildContext()));
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
});

after(() => {
  if (server) server.close();
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

function api(method, urlPath, body) {
  return fetch(`${base}${urlPath}`, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-Workdir': WORKDIR },
    body: body ? JSON.stringify(body) : undefined,
  });
}

test('a round fans out to mentioned members in order with correct attribution', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Builders',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;
  assert.ok(group.id);

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: 'please @codex then @claude build the thing',
  })).json();
  assert.equal(round.ok, true);
  assert.deepEqual(
    round.turns.map((t) => t.agent),
    ['codex', 'claude'],
  );

  const histResp = await (await api('GET', `/api/group/history?groupId=${group.id}`)).json();
  const messages = histResp.messages;

  // Exactly one human message (recorded once per round, not per summoned agent).
  const humans = messages.filter((m) => m.role === 'user');
  assert.equal(humans.length, 1);
  assert.equal(humans[0].metadata.author, 'human');

  // Assistant messages attributed to each member, in summon order.
  const assistants = messages.filter((m) => m.role === 'assistant');
  assert.equal(assistants.length, 2);
  assert.equal(assistants[0].metadata.author, 'codex');
  assert.equal(assistants[0].metadata.summonedBy, 'human');
  assert.match(assistants[0].content, /reply from codex/);
  assert.equal(assistants[1].metadata.author, 'claude');
  assert.match(assistants[1].content, /reply from claude/);

  // The round announces itself on the shared stream so other devices stay in
  // sync: the human echo and a terminal group_done (which triggers their
  // reconcile reload), both tagged with this group's id.
  const roundEvents = sentEvents.filter((e) => e.payload.groupId === group.id);
  const types = roundEvents.map((e) => e.type);
  assert.ok(types.includes('group_message'), 'expected a group_message broadcast');
  assert.ok(types.includes('group_done'), 'expected a group_done broadcast');
});

test('each member resumes its own group session key, not the group transcript key', () => {
  const codexCall = runCalls.find((c) => c.agentKey === 'codex');
  const claudeCall = runCalls.find((c) => c.agentKey === 'claude');
  assert.ok(codexCall && claudeCall);
  // Member CLI session = `${workdir}\0${agent}\0${groupId}` — distinct per member,
  // and never the group transcript key `${workdir}\0group:${groupId}`.
  assert.match(codexCall.sessionKey, new RegExp(`^${WORKDIR}\\x00codex\\x00`));
  assert.match(claudeCall.sessionKey, new RegExp(`^${WORKDIR}\\x00claude\\x00`));
  assert.ok(!codexCall.sessionKey.includes('group:'));
});

test('same-message mentions run in parallel off one snapshot, not seeing each other', () => {
  const codexCall = runCalls.find((c) => c.agentKey === 'codex');
  const claudeCall = runCalls.find((c) => c.agentKey === 'claude');
  // Both see the human turn and are told it is their turn.
  assert.match(codexCall.prompt, /Human: please .*build the thing/);
  assert.match(claudeCall.prompt, /Human: please .*build the thing/);
  assert.match(codexCall.prompt, /your turn, Codex/);
  assert.match(claudeCall.prompt, /your turn, Claude Code/);
  // Because they were summoned together they share the pre-round snapshot, so
  // neither is fed the sibling's reply — that independence is what lets them run
  // concurrently instead of one-after-another.
  assert.ok(!codexCall.prompt.includes('reply from claude'));
  assert.ok(!claudeCall.prompt.includes('reply from codex'));
});

test('a later message still sees earlier replies, so cross-round stays collaborative', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Relay Builders',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;

  // Round 1: only Codex speaks.
  await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@codex kick things off',
  })).json();

  // Round 2 (a separate message): Claude now sees Codex's earlier reply, because
  // its delta is snapshotted after round 1 was recorded.
  const before = runCalls.length;
  await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude build on that',
  })).json();
  const claudeCall = runCalls.slice(before).find((c) => c.agentKey === 'claude');
  assert.ok(claudeCall);
  assert.match(claudeCall.prompt, /Codex: reply from codex/);
});

test('a message with no mention is recorded but summons no one', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Quiet',
    members: ['claude'],
  })).json();
  const group = created.group;
  const before = runCalls.length;

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: 'just thinking out loud, no summon here',
  })).json();
  assert.deepEqual(round.turns, []);
  assert.equal(runCalls.length, before);

  const histResp = await (await api('GET', `/api/group/history?groupId=${group.id}`)).json();
  assert.equal(histResp.messages.length, 1);
  assert.equal(histResp.messages[0].role, 'user');
});

test('a swarm runs in its chosen work tree with each member its configured settings', async () => {
  const workTree = '/tmp/group-int-tree';
  const claudeConfig = { permission: 'plan' };
  const created = await (await api('POST', '/api/groups', {
    name: 'Tree',
    members: ['claude'],
    workdir: workTree,
    configs: { claude: claudeConfig },
  })).json();
  const group = created.group;
  // The work tree and per-member config round-trip in the payload.
  assert.equal(group.workdir, workTree);
  assert.deepEqual(group.memberConfigs.claude, normalizeSettings('claude', claudeConfig));

  const before = runCalls.length;
  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude go',
  })).json();
  assert.equal(round.ok, true);

  const call = runCalls.slice(before).find((c) => c.agentKey === 'claude');
  assert.ok(call);
  // The member runs in the work tree, not the workspace, and with the swarm's
  // configured settings rather than its solo-chat defaults.
  assert.equal(call.workdir, workTree);
  assert.match(call.sessionKey, new RegExp(`^${workTree}\\x00claude\\x00`));
  assert.deepEqual(call.settings, normalizeSettings('claude', claudeConfig));
});

test('unknown group and empty members are rejected', async () => {
  const missing = await api('GET', '/api/group/history?groupId=does-not-exist');
  assert.equal(missing.status, 404);

  const noMembers = await api('POST', '/api/groups', { name: 'X', members: ['ghost'] });
  assert.equal(noMembers.status, 400);
});
