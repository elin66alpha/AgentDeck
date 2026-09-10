'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { after, test } = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-history-test-'));
const historyFile = path.join(tempDir, 'chat-history.json');
process.env.RELAY_HISTORY_FILE = historyFile;

const {
  readHistory,
  upsertHistoryMessage,
  updateHistoryMessage,
  finalizeStaleStreamingHistory,
  finalizeAllStaleStreamingHistory,
  clearHistory,
  flushHistory,
  recentWorkdirs,
} = require('../lib/history');

test('recentWorkdirs lists each workdir once, latest message first', () => {
  const message = (id, createdAt) => ({ id, role: 'user', content: id, createdAt });
  upsertHistoryMessage('/tmp/recent-old\u0000claude', message('a', '2099-01-01T00:00:00.000Z'));
  upsertHistoryMessage('/tmp/recent-new\u0000codex\u0000s1', message('b', '2099-02-01T00:00:00.000Z'));
  upsertHistoryMessage('/tmp/recent-old\u0000codex', message('c', '2098-01-01T00:00:00.000Z'));

  assert.deepEqual(recentWorkdirs().slice(0, 2), ['/tmp/recent-new', '/tmp/recent-old']);
  assert.deepEqual(recentWorkdirs(1), ['/tmp/recent-new']);
});

after(() => {
  try {
    flushHistory();
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
    delete process.env.RELAY_HISTORY_FILE;
  }
});

function scopeKey(name) {
  return `/tmp/relay-${name}\u0000claude`;
}

function savedHistory() {
  return JSON.parse(fs.readFileSync(historyFile, 'utf-8'));
}

test('history cache, flush, trimming, metadata, and streaming finalization', async (t) => {
  await t.test('upsert then read is consistent before disk flush', () => {
    const key = scopeKey('read');

    upsertHistoryMessage(key, {
      id: 'm1',
      role: 'user',
      content: 'hello',
    });

    assert.deepEqual(readHistory(key), [
      {
        id: 'm1',
        role: 'user',
        content: 'hello',
      },
    ]);
  });

  await t.test('debounced flush eventually writes the file', async () => {
    const key = scopeKey('debounce');

    upsertHistoryMessage(key, {
      id: 'm1',
      role: 'assistant',
      content: 'eventual',
    });

    await delay(700);

    assert.equal(savedHistory()[key][0].content, 'eventual');
  });

  await t.test('flushHistory writes synchronously', () => {
    const key = scopeKey('sync');

    upsertHistoryMessage(key, {
      id: 'm1',
      role: 'assistant',
      content: 'sync',
    });
    flushHistory();

    assert.equal(savedHistory()[key][0].content, 'sync');
  });

  await t.test('MAX_PER_SCOPE trimming keeps the newest 200 messages', () => {
    const key = scopeKey('trim');

    for (let i = 0; i < 205; i += 1) {
      upsertHistoryMessage(key, {
        id: `m${i}`,
        role: 'assistant',
        content: `message ${i}`,
      });
    }

    const list = readHistory(key);
    assert.equal(list.length, 200);
    assert.equal(list[0].id, 'm5');
    assert.equal(list[199].id, 'm204');
  });

  await t.test('upsert metadata merge is preserved', () => {
    const key = scopeKey('metadata');

    upsertHistoryMessage(key, {
      id: 'm1',
      role: 'assistant',
      content: 'first',
      metadata: {
        left: true,
        keep: 'old',
      },
    });
    upsertHistoryMessage(key, {
      id: 'm1',
      content: 'second',
      metadata: {
        right: true,
        keep: 'new',
      },
    });

    assert.deepEqual(readHistory(key)[0], {
      id: 'm1',
      role: 'assistant',
      content: 'second',
      metadata: {
        left: true,
        keep: 'new',
        right: true,
      },
    });
  });

  await t.test('update and clear return values are preserved', () => {
    const key = scopeKey('update-clear');

    assert.equal(updateHistoryMessage(key, 'missing', (message) => message), false);
    upsertHistoryMessage(key, {
      id: 'm1',
      role: 'assistant',
      content: 'before',
    });

    assert.equal(
      updateHistoryMessage(key, 'm1', (message) => ({
        ...message,
        content: 'after',
      })),
      true,
    );
    assert.equal(readHistory(key)[0].content, 'after');
    assert.equal(clearHistory(key), true);
    assert.equal(clearHistory(key), false);
    assert.deepEqual(readHistory(key), []);
  });

  await t.test('finalizeStaleStreamingHistory cancels streaming messages', () => {
    const key = scopeKey('finalize-one');

    upsertHistoryMessage(key, {
      id: 'streaming',
      role: 'assistant',
      content: 'partial',
      updatedAt: 'old',
      metadata: {
        streaming: true,
        awaitingFirstToken: true,
        source: 'test',
      },
    });
    upsertHistoryMessage(key, {
      id: 'done',
      role: 'assistant',
      content: 'complete',
      metadata: {
        streaming: false,
      },
    });

    assert.equal(finalizeStaleStreamingHistory(key), 1);

    const streaming = readHistory(key).find((message) => message.id === 'streaming');
    const done = readHistory(key).find((message) => message.id === 'done');
    assert.equal(streaming.metadata.streaming, false);
    assert.equal(streaming.metadata.awaitingFirstToken, false);
    assert.equal(streaming.metadata.cancelled, true);
    assert.equal(streaming.metadata.source, 'test');
    assert.notEqual(streaming.updatedAt, 'old');
    assert.equal(done.metadata.streaming, false);
  });

  await t.test('finalizeAllStaleStreamingHistory still returns changed count', () => {
    const key = scopeKey('finalize-all');

    upsertHistoryMessage(key, {
      id: 'streaming',
      role: 'assistant',
      content: 'partial',
      metadata: {
        streaming: true,
        awaitingFirstToken: true,
      },
    });

    assert.equal(finalizeAllStaleStreamingHistory(), 1);
    assert.equal(readHistory(key)[0].metadata.streaming, false);
    assert.equal(readHistory(key)[0].metadata.cancelled, true);
  });
});
