'use strict';

// A stand-in `codex app-server`: speaks the real app-server protocol so the
// codex driver's distinct behaviour — a turn that completes on a notification
// rather than on the response — is exercised for real. Behaviour is driven by
// magic prompts (`hang`, `die`, `perm`, `retry`) and every notable event is
// appended to FAKE_CODEX_STATE for the test to assert on.
const fs = require('fs');

const statePath = process.env.FAKE_CODEX_STATE || '';
const noResume = process.env.FAKE_CODEX_NO_RESUME === '1';
const accountType = process.env.FAKE_CODEX_ACCOUNT_TYPE || 'chatgpt';

function record(line) {
  if (!statePath) return;
  try {
    fs.appendFileSync(statePath, `${line}\n`);
  } catch (_err) {
    // The test may have torn the scratch dir down already.
  }
}

function write(frame) {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}

function notify(method, params) {
  write({ jsonrpc: '2.0', method, params });
}

const threads = new Map();
let counter = 0;
const running = new Map();

record(`spawn ${process.pid}`);

function finishTurn(threadId, turnId, status) {
  running.delete(threadId);
  notify('turn/completed', { threadId, turn: { id: turnId, status } });
}

function handleTurnStart(msg) {
  const { threadId, input } = msg.params;
  const text = input.map((part) => part.text).join('');
  if (!threads.has(threadId)) {
    write({
      jsonrpc: '2.0',
      id: msg.id,
      error: { code: -32602, message: `unknown thread ${threadId}` },
    });
    return;
  }
  counter += 1;
  const turnId = `turn-${counter}`;
  record(
    `turn ${threadId} ${turnId} ${text} model=${msg.params.model || '-'} effort=${
      msg.params.effort || '-'
    }`,
  );
  // The response only accepts the turn; completion comes later.
  const accept = () => {
    write({
      jsonrpc: '2.0',
      id: msg.id,
      result: { turn: { id: turnId, status: 'inProgress' } },
    });
    record(`accepted ${turnId}`);
    running.set(threadId, turnId);
  };

  if (text === 'hang-slow') {
    // Accepted late, so a client can cancel before it has an id to interrupt.
    setTimeout(accept, 150);
    return;
  }
  accept();

  if (text === 'hang') return;
  if (text === 'die') {
    notify('item/agentMessage/delta', { threadId, turnId, itemId: 'i1', delta: 'partial' });
    process.exit(3);
  }
  if (text === 'retry') {
    // A retryable error is codex saying it is still working: the pool must not
    // fail the turn on it.
    notify('error', { threadId, turnId, willRetry: true, error: { message: 'transient' } });
    notify('item/agentMessage/delta', { threadId, turnId, itemId: 'i1', delta: 'recovered' });
    finishTurn(threadId, turnId, 'completed');
    return;
  }
  if (text === 'boom') {
    notify('error', { threadId, turnId, willRetry: false, error: { message: 'codex blew up' } });
    return;
  }
  if (text === 'perm') {
    write({
      jsonrpc: '2.0',
      id: 9000 + counter,
      method: 'item/fileChange/requestApproval',
      params: { threadId, turnId, itemId: 'edit-1' },
    });
    running.set(threadId, turnId);
    threads.get(threadId).pendingApproval = turnId;
    return;
  }
  if (text === 'two') {
    notify('item/agentMessage/delta', { threadId, turnId, itemId: 'first', delta: 'one' });
    notify('item/agentMessage/delta', { threadId, turnId, itemId: 'second', delta: 'two' });
    finishTurn(threadId, turnId, 'completed');
    return;
  }
  notify('item/completed', {
    threadId,
    turnId,
    completedAtMs: 0,
    item: { id: 'c1', type: 'commandExecution', command: ['ls', '-la'] },
  });
  notify('item/agentMessage/delta', { threadId, turnId, itemId: 'i1', delta: `echo:${text}` });
  finishTurn(threadId, turnId, 'completed');
}

function handle(msg) {
  if (msg.method === undefined && msg.id !== undefined) {
    // A reply to our approval request.
    for (const [threadId, thread] of threads) {
      if (!thread.pendingApproval) continue;
      const turnId = thread.pendingApproval;
      thread.pendingApproval = null;
      const decision = (msg.result && msg.result.decision) || 'none';
      record(`approval ${decision}`);
      notify('item/agentMessage/delta', {
        threadId,
        turnId,
        itemId: 'i1',
        delta: `approval:${decision}`,
      });
      finishTurn(threadId, turnId, 'completed');
      return;
    }
    return;
  }

  const reply = (result) => write({ jsonrpc: '2.0', id: msg.id, result });
  const fail = (message) =>
    write({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message } });
  const params = msg.params || {};

  switch (msg.method) {
    case 'initialize':
      reply({ userAgent: 'fake-codex/0' });
      return;
    case 'account/read':
      record(`account refresh=${params.refreshToken === true}`);
      if (process.env.FAKE_CODEX_AUTH_REJECTED === '1') {
        fail('OAuth refresh token was rejected: refresh_token_expired');
        return;
      }
      reply({
        account:
          accountType === 'none'
            ? null
            : {
                type: accountType,
                email: 'must-not-leave-the-backend@example.invalid',
              },
        requiresOpenaiAuth: accountType !== 'none',
      });
      return;
    case 'thread/start': {
      counter += 1;
      const id = `th-${process.pid}-${counter}`;
      threads.set(id, { cwd: params.cwd });
      record(`start ${id} ${params.cwd} sandbox=${params.sandbox || '-'}`);
      reply({ thread: { id } });
      return;
    }
    case 'thread/resume': {
      if (noResume) {
        record(`resume-failed ${params.threadId}`);
        fail('thread not found');
        return;
      }
      threads.set(params.threadId, { cwd: params.cwd });
      record(`resume ${params.threadId} ${params.cwd} sandbox=${params.sandbox || '-'}`);
      reply({ thread: { id: params.threadId } });
      return;
    }
    case 'turn/start':
      handleTurnStart(msg);
      return;
    case 'turn/interrupt': {
      record(`interrupt ${params.threadId} ${params.turnId}`);
      if (running.get(params.threadId) === params.turnId) {
        finishTurn(params.threadId, params.turnId, 'interrupted');
      }
      reply({});
      return;
    }
    case 'thread/unsubscribe':
      record(`unsubscribe ${params.threadId}`);
      threads.delete(params.threadId);
      reply({});
      return;
    case 'thread/delete':
      record(`delete ${params.threadId}`);
      threads.delete(params.threadId);
      reply({});
      return;
    default:
      fail(`unsupported method: ${msg.method}`);
  }
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch (_err) {
      // Malformed input is not this fixture's problem.
    }
  }
});
process.stdin.on('end', () => {
  record(`exit ${process.pid}`);
  process.exit(0);
});
