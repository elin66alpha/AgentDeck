'use strict';

// The pool mechanics (cap, idle eviction, waiters, process lifecycle) live in
// stdio-agent-pool.js and are covered by acp-session-pool.test.js. This file
// covers what is specific to codex's app-server protocol.
const { test, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { createCodexSessionPool } = require('../lib/codex-session-pool');

const AGENT = path.join(__dirname, 'fixtures', 'fake-codex-agent.js');

// A failing assertion skips the test's own cleanup, and a live agent process
// keeps the runner from exiting — which hides the failure behind a hang.
const opened = [];
after(async () => {
  for (const cleanup of opened) await cleanup();
});

function makePool(options = {}) {
  const statePath = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), 'relay-codex-')),
    'state.log',
  );
  fs.writeFileSync(statePath, '');
  const childEnv = { FAKE_CODEX_STATE: statePath, ...(options.agentEnv || {}) };
  const pool = createCodexSessionPool({
    agentKey: 'fake-codex',
    env: {},
    command: () => ({ cmd: process.execPath, args: [AGENT] }),
    ...options,
  });
  const previous = {};
  for (const [key, value] of Object.entries(childEnv)) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }
  const done = async () => {
    await pool.shutdown();
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  };
  opened.push(done);
  return {
    pool,
    state: () => fs.readFileSync(statePath, 'utf8').split('\n').filter(Boolean),
    done,
  };
}

function send(pool, key, prompt, extra = {}) {
  return pool.send({ key, prompt, cwd: '/w', onMessage: () => {}, ...extra });
}

function textOf(events) {
  return events
    .filter((e) => e.type === 'delta')
    .map((e) => e.text)
    .join('');
}

async function waitFor(check, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

test('a turn is settled by turn/completed, not by the turn/start response', async () => {
  // This is the shape that separates codex from ACP: turn/start returns as soon
  // as the turn is accepted, so the reply arrives afterwards on the stream.
  const { pool, state, done } = makePool();
  const events = [];
  const first = await send(pool, 'a', 'one', { onMessage: (e) => events.push(e) });
  assert.equal(first.result.stopReason, 'completed');
  assert.equal(textOf(events), 'echo:one');
  // The command item reaches the runner so it can render a progress label.
  assert.deepEqual(
    events.filter((e) => e.type === 'item').map((e) => e.item.type),
    ['commandExecution'],
  );

  const second = await send(pool, 'a', 'two');
  assert.equal(second.sessionId, first.sessionId, 'same thread');
  assert.equal(state().filter((l) => l.startsWith('start ')).length, 1);
  await done();
});

test('account checks share the persistent app-server and can force refresh', async () => {
  const { pool, state, done } = makePool();
  const account = await pool.readAccount({ refreshToken: true });
  assert.equal(account.account.type, 'chatgpt');
  assert.equal(account.account.email, 'must-not-leave-the-backend@example.invalid');
  assert.ok(state().includes('account refresh=true'));

  await send(pool, 'a', 'after-account-check');
  assert.equal(state().filter((line) => line.startsWith('spawn ')).length, 1);
  await done();
});

test('a cold start resumes the stored thread id', async () => {
  const { pool, state, done } = makePool();
  const result = await send(pool, 'a', 'one', { resumeId: 'stored-thread' });
  assert.ok(state().some((l) => l.startsWith('resume stored-thread /w')));
  assert.equal(result.sessionId, 'stored-thread');
  assert.equal(result.startedNew, false);
  await done();
});

test('an unresumable thread falls back to a new one and says so', async () => {
  const { pool, state, done } = makePool({
    agentEnv: { FAKE_CODEX_NO_RESUME: '1' },
  });
  const result = await send(pool, 'a', 'one', { resumeId: 'gone' });
  assert.notEqual(result.sessionId, 'gone');
  assert.equal(result.startedNew, true);
  assert.ok(state().some((l) => l.startsWith('start ')));
  await done();
});

test('model and effort ride along on every turn, with no reopen', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one', { model: 'gpt-x', effort: 'high' });
  await send(pool, 'a', 'two', { model: 'gpt-y', effort: 'low' });
  const turns = state().filter((l) => l.startsWith('turn '));
  assert.ok(turns[0].endsWith('model=gpt-x effort=high'));
  assert.ok(turns[1].endsWith('model=gpt-y effort=low'));
  // Changing them costs nothing: one thread, one process.
  assert.equal(state().filter((l) => l.startsWith('start ')).length, 1);
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  await done();
});

test('a sandbox change reopens the thread but resumes the same conversation', async () => {
  // The sandbox is fixed when a thread opens, so it is the one setting the
  // runner passes as fixedKey.
  const { pool, state, done } = makePool();
  const first = await send(pool, 'a', 'one', {
    sandbox: 'read-only',
    fixedKey: 'read-only',
  });
  const second = await send(pool, 'a', 'two', {
    sandbox: 'workspace-write',
    fixedKey: 'workspace-write',
  });
  assert.equal(second.sessionId, first.sessionId, 'same conversation');
  assert.ok(state().includes(`unsubscribe ${first.sessionId}`));
  assert.ok(
    state().some((l) =>
      l.startsWith(`resume ${first.sessionId} /w sandbox=workspace-write`),
    ),
    'reopened with the new sandbox',
  );
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  await done();
});

test('cancelling interrupts the accepted turn and leaves the thread usable', async () => {
  const { pool, state, done } = makePool();
  const controller = new AbortController();
  const pending = send(pool, 'a', 'hang', { signal: controller.signal });
  // The turn id only exists once the turn is accepted, and it is the only
  // thing that can be interrupted.
  await waitFor(() => state().some((l) => l.startsWith('accepted ')));
  controller.abort();
  await assert.rejects(pending, (err) => err.code === 'AGENT_CANCELLED');
  assert.ok(state().some((l) => l.startsWith('interrupt ')));

  const next = await send(pool, 'a', 'after');
  assert.equal(next.result.stopReason, 'completed');
  assert.equal(state().filter((l) => l.startsWith('start ')).length, 1);
  await done();
});

test('cancelling before the turn is accepted still interrupts it', async () => {
  // turn/start returns asynchronously, so a fast cancel lands while there is
  // nothing to interrupt yet. Doing nothing would leave codex running the turn
  // until the pool gave up and dropped the whole session.
  const { pool, state, done } = makePool({ cancelGraceMs: 30_000 });
  const controller = new AbortController();
  const pending = send(pool, 'a', 'hang-slow', { signal: controller.signal });
  await waitFor(() => state().some((l) => l.includes(' hang-slow')));
  assert.ok(
    !state().some((l) => l.startsWith('accepted ')),
    'cancelled before acceptance',
  );
  controller.abort();
  await assert.rejects(pending, (err) => err.code === 'AGENT_CANCELLED');
  assert.ok(
    await waitFor(() => state().some((l) => l.startsWith('interrupt '))),
    'interrupted as soon as the turn id arrived',
  );
  await done();
});

test('a retryable error is not treated as a failed turn', async () => {
  const { pool, done } = makePool();
  const events = [];
  const result = await send(pool, 'a', 'retry', {
    onMessage: (e) => events.push(e),
  });
  assert.equal(result.result.stopReason, 'completed');
  assert.equal(textOf(events), 'recovered');
  await done();
});

test('a non-retryable error fails the turn', async () => {
  const { pool, done } = makePool();
  await assert.rejects(send(pool, 'a', 'boom'), /codex blew up/);
  await done();
});

test('approval requests are answered with codex vocabulary', async () => {
  const { pool, state, done } = makePool();
  const approved = [];
  await send(pool, 'a', 'perm', {
    onMessage: (e) => approved.push(e),
    onPermission: () => true,
  });
  assert.ok(state().includes('approval accept'), 'not the ACP or legacy token');
  assert.equal(textOf(approved), 'approval:accept');

  // Refusing uses the decline token, and no policy at all still answers.
  await send(pool, 'b', 'perm', { onPermission: () => false });
  assert.ok(state().includes('approval decline'));
  await send(pool, 'c', 'perm');
  assert.equal(state().filter((l) => l === 'approval decline').length, 2);
  await done();
});

test('purge deletes the thread in-protocol, with no CLI to shell out to', async () => {
  const { pool, state, done } = makePool();
  const first = await send(pool, 'a', 'one');
  const purged = await pool.forget('a', { purge: true, sessionId: first.sessionId });
  assert.equal(purged, true);
  assert.ok(state().includes(`delete ${first.sessionId}`));
  assert.equal(pool.stats().live, 0);
  await done();
});

test('purge works with no live process, opening one just to delete', async () => {
  const { pool, state, done } = makePool();
  assert.equal(pool.stats().connected, false);
  const purged = await pool.forget('gone', { purge: true, sessionId: 'th-old' });
  assert.equal(purged, true);
  assert.ok(state().includes('delete th-old'));
  // And it does not leave the process behind afterwards.
  assert.equal(pool.stats().connected, false);
  await done();
});
