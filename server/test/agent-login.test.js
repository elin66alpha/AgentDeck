'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { test } = require('node:test');

const {
  createAgentLoginManager,
  selectLoginUrl,
  scriptCommand,
} = require('../lib/agent-login');

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdin = {
    writable: true,
    writes: [],
    write(value) {
      this.writes.push(value);
    },
  };
  child.killedSignal = '';
  child.kill = (signal) => {
    child.killedSignal = signal;
  };
  return child;
}

test('scriptCommand quotes login args for script -qfec', () => {
  assert.equal(
    scriptCommand(['codex', 'login', '--device-auth']),
    "'codex' 'login' '--device-auth'",
  );
});

test('selectLoginUrl prefers auth URLs over incidental links', () => {
  assert.deepEqual(
    selectLoginUrl('codex', [
      'https://docs.example.test/setup',
      'https://auth.openai.com/oauth/authorize?client_id=codex',
    ]).url,
    'https://auth.openai.com/oauth/authorize?client_id=codex',
  );
  assert.deepEqual(
    selectLoginUrl('claude', [
      'https://example.test/help',
      'https://claude.ai/oauth/authorize?client_id=claude.',
    ]).url,
    'https://claude.ai/oauth/authorize?client_id=claude',
  );
});

test('login manager streams URL events and writes submitted code to PTY stdin', () => {
  let spawned;
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    randomUUID: () => 'login-1',
    spawn(command, args, options) {
      spawned = { command, args, options };
      return child;
    },
  });

  const session = manager.start('codex');
  const events = [];
  manager.subscribe(session.id, (event) => events.push(event));

  child.stdout.emit(
    'data',
    'Docs https://example.test/docs Open https://auth.openai.com/oauth/authorize?client_id=codex to continue\n',
  );
  child.stderr.emit('data', 'Troubleshooting: https://example.test/help\n');
  manager.submitCode(session.id, 'abc123');
  child.emit('exit', 0);

  assert.equal(spawned.command, 'script');
  assert.deepEqual(spawned.args, [
    '-qfec',
    "'codex' 'login' '--device-auth'",
    '/dev/null',
  ]);
  assert.equal(spawned.options.stdio[0], 'pipe');
  assert.equal(child.stdin.writes[0], 'abc123\n');
  assert.ok(events.some((event) => event.type === 'login_started'));
  assert.deepEqual(
    events.find((event) => event.type === 'login_url').data.url,
    'https://auth.openai.com/oauth/authorize?client_id=codex',
  );
  assert.equal(
    events.filter((event) => event.type === 'login_url').at(-1).data.url,
    'https://auth.openai.com/oauth/authorize?client_id=codex',
  );
  assert.ok(events.some((event) => event.type === 'login_done'));
});

test('login manager keeps a running login alive when the last listener disconnects', () => {
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    randomUUID: () => 'login-disconnect',
    spawn() {
      return child;
    },
  });

  const session = manager.start('codex');
  const unsubscribe = manager.subscribe(session.id, () => {});
  unsubscribe();

  // Disconnecting (e.g. the app backgrounded to authorize in a browser) must not
  // kill the login; the CLI finishes the OAuth flow on its own. The session is
  // only reaped later by the maxRunningMs timeout.
  const status = manager.status(session.id);
  assert.equal(child.killedSignal, '');
  assert.equal(status.status, 'running');
});

test('login manager cleanup reaps expired running sessions', () => {
  let now = 1000;
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    maxRunningMs: 50,
    now: () => now,
    randomUUID: () => 'login-timeout',
    spawn() {
      return child;
    },
  });

  const session = manager.start('codex');
  now += 51;
  manager.cleanup();

  const status = manager.status(session.id);
  assert.equal(child.killedSignal, 'SIGTERM');
  assert.equal(status.status, 'error');
  assert.match(status.error, /timed out/i);
});

test('login manager rejects unsupported and missing CLIs clearly', () => {
  const manager = createAgentLoginManager({ commandExists: () => false });

  assert.throws(() => manager.start('hermes'), /not supported/);
  assert.throws(() => manager.start('codex'), /not installed/);
});
