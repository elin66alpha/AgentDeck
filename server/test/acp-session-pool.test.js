'use strict';

const { test, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { createAcpSessionPool } = require('../lib/acp-session-pool');

const AGENT = path.join(__dirname, 'fixtures', 'fake-acp-agent.js');

// A failing assertion skips the test's own cleanup, and a live agent process
// keeps the runner from exiting — which hides the failure behind a hang.
const opened = [];
after(async () => {
  for (const cleanup of opened) await cleanup();
});

// Each pool gets its own state file, so the assertions below read exactly what
// this test's agent process saw.
function makePool(options = {}) {
  const statePath = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), 'relay-acp-')),
    'state.log',
  );
  fs.writeFileSync(statePath, '');
  const childEnv = { FAKE_ACP_STATE: statePath, ...(options.agentEnv || {}) };
  const pool = createAcpSessionPool({
    agentKey: 'fake',
    env: {},
    command: () => ({
      cmd: process.execPath,
      args: [AGENT],
      // The fixture reads its flags from the environment it inherits.
    }),
    ...options,
  });
  // The pool spawns with process.env, so the flags have to live there. They are
  // restored when the pool shuts down.
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
    state: () =>
      fs
        .readFileSync(statePath, 'utf8')
        .split('\n')
        .filter(Boolean),
    done,
  };
}

function send(pool, key, prompt, extra = {}) {
  return pool.send({
    key,
    prompt,
    cwd: '/w',
    onMessage: () => {},
    ...extra,
  });
}

function textOf(updates) {
  return updates
    .filter((u) => u.sessionUpdate === 'agent_message_chunk')
    .map((u) => u.content.text)
    .join('');
}

// Wait for a condition the agent process reports asynchronously.
async function waitFor(check, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

test('a second turn reuses the live session instead of opening another', async () => {
  const { pool, state, done } = makePool();
  const updates = [];
  const first = await send(pool, 'a', 'one', {
    onMessage: (u) => updates.push(u),
  });
  const second = await send(pool, 'a', 'two');
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  assert.equal(state().filter((l) => l.startsWith('new ')).length, 1);
  assert.equal(first.sessionId, second.sessionId);
  assert.equal(textOf(updates), 'echo:one');
  assert.equal(second.result.stopReason, 'end_turn');
  await done();
});

test('several scopes share one agent process', async () => {
  // This is the whole point of ACP over the Claude SDK: opencode costs ~360MB
  // to boot, and that is paid once rather than once per chat.
  const { pool, state, done } = makePool();
  const a = await send(pool, 'a', 'one', { cwd: '/w1' });
  const b = await send(pool, 'b', 'one', { cwd: '/w2' });
  assert.notEqual(a.sessionId, b.sessionId, 'independent sessions');
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  // cwd is per session, so two work trees still share the process.
  assert.ok(state().includes(`new ${a.sessionId} /w1`));
  assert.ok(state().includes(`new ${b.sessionId} /w2`));
  assert.equal(pool.stats().live, 2);
  await done();
});

test('a cold start loads the stored session id', async () => {
  const { pool, state, done } = makePool();
  const result = await send(pool, 'a', 'one', { resumeId: 'stored-id' });
  assert.ok(state().includes('load stored-id /w'));
  assert.equal(result.sessionId, 'stored-id', 'keeps the caller session');
  assert.equal(result.startedNew, false);
  await done();
});

test('an unloadable stored session falls back to a new one and says so', async () => {
  const { pool, state, done } = makePool({ agentEnv: { FAKE_ACP_NO_LOAD: '1' } });
  const result = await send(pool, 'a', 'one', { resumeId: 'gone' });
  assert.notEqual(result.sessionId, 'gone');
  assert.equal(result.startedNew, true, 'the caller can tell the user');
  assert.equal(result.result.stopReason, 'end_turn');
  assert.ok(state().some((l) => l.startsWith('new ')));
  await done();
});

test('the model is applied over the protocol, once per session', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one', { modelId: 'prov/model-x' });
  await send(pool, 'a', 'two', { modelId: 'prov/model-x' });
  const models = state().filter((l) => l.startsWith('model '));
  assert.equal(models.length, 1, 'unchanged settings do not re-set the model');
  assert.ok(models[0].endsWith('prov/model-x'));

  // A changed model switches live — no restart, unlike the Claude pool.
  await send(pool, 'a', 'three', { modelId: 'prov/model-y' });
  assert.equal(state().filter((l) => l.startsWith('model ')).length, 2);
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  assert.equal(state().filter((l) => l.startsWith('new ')).length, 1);
  await done();
});

test('the permission mode is applied like the model, and only on change', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one', { modeId: 'dont_ask' });
  await send(pool, 'a', 'two', { modeId: 'dont_ask' });
  assert.equal(state().filter((l) => l.startsWith('mode ')).length, 1);
  await send(pool, 'a', 'three', { modeId: 'default' });
  const modes = state().filter((l) => l.startsWith('mode '));
  assert.equal(modes.length, 2);
  assert.ok(modes[1].endsWith('default'));
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  await done();
});

test('an agent without session/close still drops evicted sessions', async () => {
  // Hermes advertises no close capability: the pool must not send one, and the
  // session still leaves the pool so the cap is honoured.
  const { pool, state, done } = makePool({
    maxSessions: 1,
    agentEnv: { FAKE_ACP_NO_CLOSE: '1' },
  });
  await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  assert.equal(pool.stats().live, 1);
  assert.equal(state().filter((l) => l.startsWith('close ')).length, 0);
  assert.deepEqual(pool.stats().keys, ['b']);
  await done();
});

test('the session cap evicts the least recently used idle session', async () => {
  const { pool, state, done } = makePool({ maxSessions: 2 });
  const a = await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  assert.equal(pool.stats().live, 2);
  await send(pool, 'c', 'one');
  assert.equal(pool.stats().live, 2, 'never exceeds the cap');
  assert.ok(
    state().includes(`close ${a.sessionId}`),
    'the oldest idle session was closed on the agent too',
  );
  await done();
});

test('a turn blocked on the cap runs once another turn finishes', async () => {
  // Group chats summon several members at once, so more concurrent turns than
  // session slots is a normal state, not an error.
  const { pool, state, done } = makePool({ maxSessions: 1 });
  const controller = new AbortController();
  const busy = send(pool, 'a', 'hang', { signal: controller.signal });
  await waitFor(() => state().some((l) => l.endsWith('hang')));

  let blockedDone = false;
  const blocked = send(pool, 'b', 'queued').then((value) => {
    blockedDone = true;
    return value;
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(blockedDone, false, 'waits while the only slot is busy');
  assert.equal(pool.stats().waiting, 1);

  // Freeing the slot is what wakes the waiter — the finished turn's session is
  // evictable again.
  controller.abort();
  await assert.rejects(busy, (err) => err.code === 'AGENT_CANCELLED');
  const result = await blocked;
  assert.equal(result.result.stopReason, 'end_turn');
  assert.equal(pool.stats().live, 1, 'still within the cap');
  await done();
});

test('cancelling a turn interrupts it and leaves the session usable', async () => {
  const { pool, state, done } = makePool();
  const controller = new AbortController();
  const pending = send(pool, 'a', 'hang', { signal: controller.signal });
  await waitFor(() => state().some((l) => l.endsWith('hang')));
  controller.abort();
  await assert.rejects(pending, (err) => err.code === 'AGENT_CANCELLED');
  assert.ok(state().some((l) => l.startsWith('cancel ')), 'cancel, not kill');

  // The session survives: the next turn lands on the same one.
  const next = await send(pool, 'a', 'after');
  assert.equal(state().filter((l) => l.startsWith('new ')).length, 1);
  assert.equal(next.result.stopReason, 'end_turn');
  await done();
});

test('an already-aborted signal rejects without prompting', async () => {
  const { pool, state, done } = makePool();
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    send(pool, 'a', 'never', { signal: controller.signal }),
    (err) => err.code === 'AGENT_CANCELLED',
  );
  assert.equal(state().filter((l) => l.startsWith('prompt ')).length, 0);
  await done();
});

test('permission requests are answered by the caller policy', async () => {
  const { pool, state, done } = makePool();
  const updates = [];
  await send(pool, 'a', 'perm', {
    onMessage: (u) => updates.push(u),
    // The runner answers yes or no; picking the matching option is the
    // driver's job, so the policy never touches protocol vocabulary.
    onPermission: () => true,
  });
  assert.ok(state().includes('permission yes'));
  assert.equal(textOf(updates), 'permission:yes');

  // No policy at all must not hang the agent: it gets an explicit answer.
  await send(pool, 'b', 'perm');
  assert.ok(state().includes('permission no'), 'refused, not left hanging');
  await done();
});

test('an idle session is closed, and the process goes with the last one', async () => {
  const { pool, state, done } = makePool({ idleMs: 40 });
  const first = await send(pool, 'a', 'one');
  assert.equal(pool.stats().live, 1);
  assert.equal(pool.stats().connected, true);
  await waitFor(() => pool.stats().live === 0);
  assert.equal(pool.stats().live, 0, 'evicted once idle');
  assert.ok(state().includes(`close ${first.sessionId}`));
  // The process exists only to host sessions.
  assert.ok(await waitFor(() => pool.stats().connected === false));

  // The conversation is unaffected: the next turn cold-starts and loads.
  const second = await send(pool, 'a', 'two', { resumeId: first.sessionId });
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 2);
  assert.equal(second.sessionId, first.sessionId);
  await done();
});

test('a warm session that dies before output is retried cold', async () => {
  const { pool, state, done } = makePool();
  const first = await send(pool, 'a', 'one');
  const second = await send(pool, 'a', 'die-quiet', {
    resumeId: first.sessionId,
  });
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 2);
  assert.equal(second.result.stopReason, 'end_turn');
  await done();
});

test('a warm session that dies mid-reply is not silently re-run', async () => {
  // Retrying would replay text the user already saw.
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one');
  await assert.rejects(
    send(pool, 'a', 'die'),
    (err) => err.code === 'AGENT_SESSION_LOST' && err.emitted === true,
  );
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  await done();
});

test('every update in a turn reaches the caller, result excluded', async () => {
  const { pool, done } = makePool();
  const updates = [];
  await send(pool, 'a', 'two', { onMessage: (u) => updates.push(u) });
  assert.deepEqual(
    updates.map((u) => u.messageId),
    ['first', 'second'],
    'both assistant messages, so the runner can split them into segments',
  );
  await done();
});

test('forget without purge drops the session but keeps the transcript', async () => {
  const deleted = [];
  const { pool, state, done } = makePool({
    deleteCommand: (sessionId) => {
      deleted.push(sessionId);
      return { cmd: process.execPath, args: ['-e', ''] };
    },
  });
  const first = await send(pool, 'a', 'one');
  await pool.forget('a');
  assert.ok(state().includes(`close ${first.sessionId}`));
  assert.deepEqual(deleted, []);
  assert.equal(pool.stats().live, 0);
  await done();
});

test('forget with purge runs the delete command for the session', async () => {
  const deleted = [];
  const { pool, done } = makePool({
    deleteCommand: (sessionId) => {
      deleted.push(sessionId);
      return { cmd: process.execPath, args: ['-e', ''] };
    },
  });
  await send(pool, 'a', 'one');
  const purged = await pool.forget('a', { purge: true, sessionId: 'sess-x' });
  assert.equal(purged, true, 'the CLI reported success');
  assert.deepEqual(deleted, ['sess-x']);
  await done();
});

test('shutdown closes every session and kills the process', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  const pid = Number(
    state()
      .find((line) => line.startsWith('spawn '))
      .split(' ')[1],
  );
  await pool.shutdown();
  assert.equal(pool.stats().live, 0);
  assert.equal(pool.stats().connected, false);
  // A restart must not leave the agent behind holding memory.
  const gone = await waitFor(() => {
    try {
      process.kill(pid, 0);
      return false;
    } catch (_err) {
      return true;
    }
  });
  assert.ok(gone, 'the agent process is really gone');
  await done();
});

test('a missing binary fails the turn instead of the server', async () => {
  const pool = createAcpSessionPool({
    agentKey: 'fake',
    env: {},
    command: () => null,
  });
  await assert.rejects(send(pool, 'a', 'one'), /not installed/);
  await pool.shutdown();
});
