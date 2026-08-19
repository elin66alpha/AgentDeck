'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  authorOf,
  parseMentions,
  deltaSince,
  buildGroupPrompt,
} = require('../lib/group-turn');

const LABELS = {
  claude: 'Claude Code',
  codex: 'Codex',
  opencode: 'OpenCode',
};
const labelFor = (key) => LABELS[key] || key;

function human(content) {
  return { role: 'user', content, metadata: { author: 'human' } };
}

function agentMsg(agentKey, content) {
  return { role: 'assistant', agent: agentKey, content, metadata: { author: agentKey } };
}

test('authorOf prefers explicit metadata, then role/agent', () => {
  assert.equal(authorOf({ metadata: { author: 'codex' } }), 'codex');
  assert.equal(authorOf({ role: 'user' }), 'human');
  assert.equal(authorOf({ role: 'assistant', agent: 'claude' }), 'claude');
  assert.equal(authorOf(null), '');
});

test('parseMentions returns summoned members in order, de-duplicated', () => {
  const members = ['claude', 'codex', 'opencode'];
  assert.deepEqual(
    parseMentions('hey @codex and @claude, then @codex again', members, labelFor),
    ['codex', 'claude'],
  );
});

test('parseMentions only matches current members and ignores email-like tokens', () => {
  const members = ['claude', 'codex'];
  // @opencode is not a member; foo@codex is an email-like token (preceded by a word char).
  assert.deepEqual(parseMentions('ping @opencode please', members, labelFor), []);
  assert.deepEqual(parseMentions('mail foo@codex now', members, labelFor), []);
  assert.deepEqual(parseMentions('@claude go', members, labelFor), ['claude']);
});

test('parseMentions matches by label slug as well as agent key', () => {
  const members = ['claude', 'codex'];
  assert.deepEqual(parseMentions('@ClaudeCode look here', members, labelFor), ['claude']);
});

test('parseMentions ignores broad @all / @everyone aliases', () => {
  const members = ['claude', 'codex', 'opencode'];
  assert.deepEqual(parseMentions('@all huddle up', members, labelFor), []);
  assert.deepEqual(parseMentions('@everyone huddle up', members, labelFor), []);
});

test('deltaSince returns everything for an agent that never spoke', () => {
  const messages = [human('hi'), agentMsg('claude', 'hello')];
  assert.deepEqual(deltaSince(messages, 'codex'), messages);
});

test('deltaSince returns only messages after the agent last spoke', () => {
  const messages = [
    human('start'),
    agentMsg('claude', 'first'),
    human('reply'),
    agentMsg('codex', 'mid'),
    human('again'),
  ];
  assert.deepEqual(deltaSince(messages, 'claude'), [
    messages[2],
    messages[3],
    messages[4],
  ]);
});

test('buildGroupPrompt labels each speaker and marks the agent turn', () => {
  const delta = [human('build the parser'), agentMsg('codex', 'I can start the lexer')];
  const prompt = buildGroupPrompt({ selfLabel: 'Claude Code', delta, labelFor });
  assert.match(prompt, /You are "Claude Code"/);
  assert.match(prompt, /Human: build the parser/);
  assert.match(prompt, /Codex: I can start the lexer/);
  assert.match(prompt, /It is now your turn, Claude Code\./);
});

test('buildGroupPrompt handles an empty delta', () => {
  const prompt = buildGroupPrompt({ selfLabel: 'Codex', delta: [], labelFor });
  assert.match(prompt, /\(no new messages\)/);
});

test('buildGroupPrompt injects the member persona when given', () => {
  const delta = [human('start')];
  const prompt = buildGroupPrompt({
    selfLabel: 'Codex',
    persona: 'Own the database schema',
    delta,
    labelFor,
  });
  assert.match(prompt, /Your role in this swarm: Own the database schema/);
  // No persona -> no role line.
  const plain = buildGroupPrompt({ selfLabel: 'Codex', delta, labelFor });
  assert.doesNotMatch(plain, /Your role in this swarm/);
});

test('buildGroupPrompt lists the members this one can summon', () => {
  const delta = [human('start')];
  const prompt = buildGroupPrompt({
    selfLabel: 'Claude Code',
    delta,
    labelFor,
    roster: [
      { key: 'codex', label: 'Codex' },
      { key: 'opencode', label: 'Schema owner' },
    ],
  });
  // The @key form is what parseMentions always resolves, so it is what the
  // agent is shown — a multi-word nickname alone would not parse.
  assert.match(
    prompt,
    /Other members of this swarm: Codex \(@codex\), Schema owner \(@opencode\)\./,
  );
  // Without a roster (agent-to-agent summoning off) the prompt promises nothing.
  const alone = buildGroupPrompt({ selfLabel: 'Claude Code', delta, labelFor });
  assert.doesNotMatch(alone, /Other members of this swarm/);
});

test('buildGroupPrompt bounds the prompt and notes omitted history', () => {
  const big = 'x'.repeat(2000);
  const delta = [];
  for (let i = 0; i < 50; i += 1) delta.push(human(`${i} ${big}`));
  const maxBytes = 8 * 1024;
  const prompt = buildGroupPrompt({ selfLabel: 'Codex', delta, labelFor, maxBytes });
  assert.ok(Buffer.byteLength(prompt, 'utf8') <= maxBytes);
  assert.match(prompt, /\[earlier messages omitted\]/);
  // The most recent message must survive the truncation.
  assert.match(prompt, /Human: 49 /);
});
