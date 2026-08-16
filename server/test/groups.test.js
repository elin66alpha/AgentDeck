'use strict';

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Point the store at a scratch file before requiring the module (the path is
// resolved from the env at require time, like history.js).
const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-groups-'));
process.env.RELAY_GROUPS_FILE = path.join(scratchDir, 'groups.json');

const groups = require('../lib/groups');

before(() => {
  fs.rmSync(process.env.RELAY_GROUPS_FILE, { force: true });
});

after(() => {
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

test('createGroup persists and is retrievable by id and workdir', () => {
  const workdir = '/tmp/wd-create';
  const group = groups.createGroup(workdir, 'Builders', ['claude', 'codex']);
  assert.ok(group.id);
  assert.equal(group.name, 'Builders');
  assert.deepEqual(group.members, ['claude', 'codex']);

  assert.deepEqual(groups.getGroup(workdir, group.id).members, ['claude', 'codex']);
  assert.equal(groups.listGroups(workdir).length, 1);

  // A fresh persistence is proven by reading the file back.
  const onDisk = JSON.parse(fs.readFileSync(process.env.RELAY_GROUPS_FILE, 'utf-8'));
  assert.equal(onDisk[workdir].groups[0].id, group.id);
});

test('members are de-duplicated, order-preserving, and capped', () => {
  const workdir = '/tmp/wd-members';
  const many = [];
  for (let i = 0; i < 20; i += 1) many.push(`agent-${i}`);
  const group = groups.createGroup(workdir, 'Big', ['claude', 'claude', 'codex', ...many]);
  assert.equal(group.members.length, groups.MAX_MEMBERS);
  assert.equal(group.members[0], 'claude');
  assert.equal(group.members[1], 'codex');
  // No duplicate claude.
  assert.equal(group.members.filter((m) => m === 'claude').length, 1);
});

test('createGroup returns null when there are no valid members', () => {
  assert.equal(groups.createGroup('/tmp/wd-empty', 'Nope', []), null);
  assert.equal(groups.createGroup('/tmp/wd-empty', 'Nope', ['bad key!']), null);
});

test('setGroupMembers replaces the roster and keeps the id', () => {
  const workdir = '/tmp/wd-set';
  const group = groups.createGroup(workdir, 'Team', ['claude']);
  const updated = groups.setGroupMembers(workdir, group.id, ['codex', 'opencode']);
  assert.equal(updated.id, group.id);
  assert.deepEqual(updated.members, ['codex', 'opencode']);
  assert.equal(groups.setGroupMembers(workdir, 'missing', ['codex']), null);
  assert.equal(groups.setGroupMembers(workdir, group.id, []), null);
});

test('createGroup stores the work tree and per-member configs, dropping junk', () => {
  const workspace = '/tmp/wd-config';
  const group = groups.createGroup(workspace, 'Tuned', ['claude', 'codex'], {
    workdir: '/tmp/wd-config/tree',
    memberConfigs: {
      claude: { model: 'm1', effort: 'high', permission: 'plan', bogus: 'x' },
      ghost: { model: 'nope' }, // not a member -> dropped
      codex: { model: 42 }, // non-string id -> dropped, leaving no config
    },
  });
  assert.equal(group.workdir, '/tmp/wd-config/tree');
  // Only known groups for current members survive; non-string ids and the
  // bogus key are stripped, and a member left with nothing is omitted.
  assert.deepEqual(group.memberConfigs, {
    claude: { model: 'm1', effort: 'high', permission: 'plan' },
  });

  // setGroupMembers re-scopes configs to the new roster (claude dropped here).
  const updated = groups.setGroupMembers(workspace, group.id, ['codex'], {
    memberConfigs: { codex: { permission: 'workspace-write' }, claude: { model: 'm1' } },
  });
  assert.equal(updated.workdir, '/tmp/wd-config/tree', 'work tree is preserved');
  assert.deepEqual(updated.memberConfigs, { codex: { permission: 'workspace-write' } });
});

test('member configs keep swarm-scoped nickname and prompt, bounded and trimmed', () => {
  const workspace = '/tmp/wd-persona';
  const group = groups.createGroup(workspace, 'Persona', ['claude', 'codex'], {
    memberConfigs: {
      claude: {
        model: 'm1',
        nickname: '  Lead  Dev  ',
        prompt: '  Own the API layer.  ',
      },
      codex: { nickname: '', prompt: '   ' }, // blank -> nothing kept
    },
  });
  assert.deepEqual(group.memberConfigs.claude, {
    model: 'm1',
    nickname: 'Lead Dev',
    prompt: 'Own the API layer.',
  });
  assert.equal(group.memberConfigs.codex, undefined, 'blank persona keeps nothing');

  const longGroup = groups.createGroup(workspace, 'Long', ['claude'], {
    memberConfigs: {
      claude: { nickname: 'n'.repeat(200), prompt: 'p'.repeat(5000) },
    },
  });
  assert.equal(longGroup.memberConfigs.claude.nickname.length, 80);
  assert.equal(longGroup.memberConfigs.claude.prompt.length, 4000);
});

test('deleteGroup removes only the targeted group', () => {
  const workdir = '/tmp/wd-delete';
  const a = groups.createGroup(workdir, 'A', ['claude']);
  const b = groups.createGroup(workdir, 'B', ['codex']);
  groups.deleteGroup(workdir, a.id);
  assert.equal(groups.getGroup(workdir, a.id), null);
  assert.ok(groups.getGroup(workdir, b.id));
  assert.equal(groups.deleteGroup(workdir, 'missing'), null);
});

test('groups are isolated per workdir', () => {
  groups.createGroup('/tmp/wd-one', 'One', ['claude']);
  groups.createGroup('/tmp/wd-two', 'Two', ['codex']);
  assert.equal(groups.listGroups('/tmp/wd-one').length, 1);
  assert.equal(groups.listGroups('/tmp/wd-two').length, 1);
  assert.equal(groups.listGroups('/tmp/wd-one')[0].name, 'One');
});

test('a workdir cannot exceed the group cap', () => {
  const workdir = '/tmp/wd-cap';
  for (let i = 0; i < groups.MAX_GROUPS_PER_WORKDIR; i += 1) {
    assert.ok(groups.createGroup(workdir, `G${i}`, ['claude']));
  }
  assert.equal(groups.createGroup(workdir, 'overflow', ['claude']), null);
});

test('validGroupId rejects separator-injection attempts', () => {
  assert.equal(groups.validGroupId('abc-123'), 'abc-123');
  assert.equal(groups.validGroupId('a\x00b'), '');
  assert.equal(groups.validGroupId('group:other'), '');
  assert.equal(groups.validGroupId(''), '');
});
