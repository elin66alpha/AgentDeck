'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { createClaudeSessionPool } = require('../lib/claude-session-pool');

// A stand-in for the Agent SDK: one fake process per query(), echoing each
// prompt pushed into the streaming input.
function fakeSdk() {
  const spawned = [];
  const deleted = [];
  let hangNext = false;
  let hangAll = false;

  function query({ prompt, options }) {
    const session = {
      options,
      prompts: [],
      closed: false,
      interrupted: 0,
      hang: hangNext || hangAll,
      sessionId: options.resume || `sess-${spawned.length + 1}`,
    };
    hangNext = false;
    spawned.push(session);
    const iterator = (async function* run() {
      for await (const message of prompt) {
        const text = String(message.message.content);
        session.prompts.push(text);
        yield { type: 'system', subtype: 'init', session_id: session.sessionId };
        if (session.hang) {
          // A long turn that only finishes when interrupted, like the CLI
          // winding down on ESC.
          await new Promise((resolve) => {
            session.release = resolve;
          });
        }
        yield {
          type: 'assistant',
          session_id: session.sessionId,
          message: { id: 'm1', content: [{ type: 'text', text: `echo:${text}` }] },
        };
        if (session.dieAfterAssistant) throw new Error('cli exited');
        yield {
          type: 'result',
          subtype: 'success',
          session_id: session.sessionId,
          result: `echo:${text}`,
        };
      }
    })();
    return {
      [Symbol.asyncIterator]: () => iterator,
      close() {
        session.closed = true;
        iterator.return();
      },
      async interrupt() {
        session.interrupted += 1;
        session.hang = false;
        if (session.release) session.release();
      },
    };
  }

  return {
    spawned,
    deleted,
    hangNextTurn() {
      hangNext = true;
    },
    hangEveryTurn() {
      hangAll = true;
    },
    releaseAll() {
      hangAll = false;
      for (const session of spawned) {
        session.hang = false;
        if (session.release) session.release();
      }
    },
    query,
    async deleteSession(id, opts) {
      deleted.push({ id, dir: opts && opts.dir });
    },
  };
}

function makePool(sdk, options = {}) {
  return createClaudeSessionPool({ sdk, env: {}, ...options });
}

function send(pool, key, prompt, extra = {}) {
  return pool.send({
    key,
    prompt,
    cwd: '/w',
    sdkOptions: { model: 'm' },
    optionsKey: 'k1',
    onMessage: () => {},
    ...extra,
  });
}

test('a second turn reuses the live session instead of spawning again', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  const first = await send(pool, 'a', 'one');
  const second = await send(pool, 'a', 'two');
  assert.equal(sdk.spawned.length, 1, 'one process for both turns');
  assert.deepEqual(sdk.spawned[0].prompts, ['one', 'two']);
  assert.equal(first.result.result, 'echo:one');
  assert.equal(second.result.result, 'echo:two');
  assert.equal(second.sessionId, 'sess-1');
  await pool.shutdown();
});

test('changed settings restart the process and resume the same conversation', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one');
  await send(pool, 'a', 'two', { optionsKey: 'k2', sdkOptions: { model: 'other' } });
  assert.equal(sdk.spawned.length, 2);
  assert.equal(sdk.spawned[0].closed, true, 'old process closed');
  assert.equal(
    sdk.spawned[1].options.resume,
    'sess-1',
    'restart resumes the conversation the user was in',
  );
  await pool.shutdown();
});

test('a cold start resumes the stored session id', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one', { resumeId: 'stored-id' });
  assert.equal(sdk.spawned[0].options.resume, 'stored-id');
  await pool.shutdown();
});

test('the live-process cap evicts the least recently used idle session', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk, { maxLive: 2 });
  await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  assert.equal(pool.stats().live, 2);
  await send(pool, 'c', 'one');
  assert.equal(pool.stats().live, 2, 'never exceeds the cap');
  assert.equal(sdk.spawned[0].closed, true, 'oldest idle session evicted');
  assert.equal(sdk.spawned[1].closed, false);
  await pool.shutdown();
});

test('a turn blocked on the cap runs once another turn finishes', async () => {
  // Group chats summon several members at once, so more concurrent turns than
  // live slots is a normal state, not an error.
  const sdk = fakeSdk();
  const pool = makePool(sdk, { maxLive: 1 });
  sdk.hangNextTurn();
  const busy = send(pool, 'a', 'slow');
  await new Promise((resolve) => setTimeout(resolve, 10));

  let blockedDone = false;
  const blocked = send(pool, 'b', 'queued').then((value) => {
    blockedDone = true;
    return value;
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(blockedDone, false, 'waits while the only slot is busy');
  assert.equal(pool.stats().waiting, 1);

  sdk.spawned[0].release();
  await busy;
  const result = await blocked;
  assert.equal(result.result.result, 'echo:queued');
  assert.equal(sdk.spawned[0].closed, true, 'the finished session made room');
  assert.equal(pool.stats().live, 1);
  await pool.shutdown();
});

test('an idle session is closed after the idle timeout', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk, { idleMs: 40 });
  await send(pool, 'a', 'one');
  assert.equal(pool.stats().live, 1);
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(pool.stats().live, 1, 'still live before the timeout');
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(pool.stats().live, 0, 'evicted once idle');
  assert.equal(sdk.spawned[0].closed, true);

  // The conversation is unaffected: the next turn cold-starts and resumes.
  await send(pool, 'a', 'two', { resumeId: 'sess-1' });
  assert.equal(sdk.spawned.length, 2);
  assert.equal(sdk.spawned[1].options.resume, 'sess-1');
  await pool.shutdown();
});

test('cancelling a turn interrupts it and rejects, leaving the session usable', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk, { interruptGraceMs: 10_000 });
  const controller = new AbortController();
  sdk.hangNextTurn();
  const pending = send(pool, 'a', 'slow', { signal: controller.signal });
  await new Promise((resolve) => setTimeout(resolve, 10));
  controller.abort();
  await assert.rejects(pending, (err) => err.code === 'AGENT_CANCELLED');
  assert.equal(sdk.spawned[0].interrupted, 1, 'interrupt, not kill');
  assert.equal(sdk.spawned[0].closed, false, 'session survives the cancel');
  await pool.shutdown();
});

test('an already-aborted signal rejects without sending a prompt', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    send(pool, 'a', 'never', { signal: controller.signal }),
    (err) => err.code === 'AGENT_CANCELLED',
  );
  assert.deepEqual(sdk.spawned[0].prompts, []);
  await pool.shutdown();
});

test('forget with purge closes the session and deletes its transcript', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one');
  const purged = await pool.forget('a', {
    purge: true,
    sessionId: 'sess-1',
    cwd: '/w',
  });
  assert.equal(purged, true);
  assert.equal(sdk.spawned[0].closed, true);
  assert.deepEqual(sdk.deleted, [{ id: 'sess-1', dir: '/w' }]);
  assert.equal(pool.stats().live, 0);
});

test('forget without purge drops the process but keeps the transcript', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one');
  await pool.forget('a');
  assert.equal(sdk.spawned[0].closed, true);
  assert.deepEqual(sdk.deleted, []);
});

test('result messages settle the turn and are not replayed as progress', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  const seen = [];
  await send(pool, 'a', 'one', { onMessage: (m) => seen.push(m.type) });
  assert.deepEqual(seen, ['system', 'assistant']);
  await pool.shutdown();
});

test('a dead warm session is retried cold rather than failing the turn', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one');
  // Simulate the CLI exiting between turns: the reader loop ends and the pool
  // drops the entry, so the next turn has to cold-start.
  sdk.spawned[0].closed = true;
  await pool.forget('a');
  const second = await send(pool, 'a', 'two', { resumeId: 'sess-1' });
  assert.equal(sdk.spawned.length, 2);
  assert.equal(second.result.result, 'echo:two');
  await pool.shutdown();
});

test('concurrent cold starts never exceed the live-process cap', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk, { maxLive: 2 });
  sdk.hangEveryTurn();
  const a = send(pool, 'a', 'one');
  const b = send(pool, 'b', 'two');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(pool.stats().live, 2);
  assert.equal(sdk.spawned.length, 2, 'the third caller did not slip past the cap');

  const blocked = send(pool, 'c', 'three');
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(sdk.spawned.length, 2);
  assert.equal(pool.stats().waiting, 1);

  sdk.releaseAll();
  await Promise.all([a, b, blocked]);
  assert.equal(sdk.spawned.length, 3, 'the blocked caller ran after a slot freed');
  assert.ok(pool.stats().live <= 2, 'still within the cap');
  await pool.shutdown();
});

test('a warm session that dies mid-reply is not silently re-run', async () => {
  // Retrying would replay text the user already saw.
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one');
  sdk.spawned[0].dieAfterAssistant = true;
  await assert.rejects(
    send(pool, 'a', 'two'),
    (err) => err.code === 'CLAUDE_SESSION_LOST' && err.emitted === true,
  );
  assert.equal(sdk.spawned.length, 1, 'no hidden retry');
  await pool.shutdown();
});

test('shutdown closes every live session', async () => {
  const sdk = fakeSdk();
  const pool = makePool(sdk);
  await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  await pool.shutdown();
  assert.equal(pool.stats().live, 0);
  assert.ok(sdk.spawned.every((s) => s.closed));
});
