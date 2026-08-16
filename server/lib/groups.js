'use strict';

// Swarm (group chat) state: a swarm is a named, ordered set of agent members
// that share one canonical transcript. It sits above the per-agent scopes (see
// docs/group-chat.md). Each member keeps its own resumable CLI session; the
// swarm additionally pins its own work tree (`workdir`) and per-member
// model/effort/permission/fast (`memberConfigs`) so it is configured independently of
// each member's solo chat.
//
// Persisted with the shared json-store (in-memory cache + atomic 0o600 writes),
// consistent with the other backend state files. The on-disk shape is:
//   { [workspace]: { groups: [ { id, name, members, workdir, memberConfigs,
//                                createdAt, updatedAt } ] } }
// keyed by the workspace it was created in; `workdir` is the chosen work tree the
// members actually run against (defaults to the workspace).

const crypto = require('crypto');
const path = require('path');

const { createJsonStore } = require('./json-store');

const GROUPS_FILE = process.env.RELAY_GROUPS_FILE
  ? path.resolve(process.env.RELAY_GROUPS_FILE)
  : path.join(__dirname, '..', 'groups.json');
// Bounds: keep the file small and cap the fan-out cost of a single round. One
// human message can summon every member, so the member cap is also a turn budget.
const MAX_GROUPS_PER_WORKDIR = 20;
const MAX_MEMBERS = 8;

const store = createJsonStore(GROUPS_FILE, { defaultValue: {} });

function validGroupId(value) {
  const text = String(value || '').trim();
  return /^[A-Za-z0-9._-]{1,96}$/.test(text) ? text : '';
}

function normalizeName(value, fallback) {
  const text = String(value || '')
    .replace(/\s+/g, ' ')
    .trim();
  return (text || fallback).slice(0, 80);
}

// Members are agent keys (claude, codex, opencode, ...). Dedupe, keep order, cap the
// count, and reject anything that isn't a plausible agent key so a member can
// never inject a separator into a derived scope key.
function normalizeMembers(members) {
  const out = [];
  const seen = new Set();
  for (const raw of Array.isArray(members) ? members : []) {
    const key = String(raw || '').trim();
    if (!key || seen.has(key)) continue;
    if (!/^[A-Za-z0-9:_-]{1,64}$/.test(key)) continue;
    seen.add(key);
    out.push(key);
    if (out.length >= MAX_MEMBERS) break;
  }
  return out;
}

// Per-member config, structurally sanitized only: the route normalizes option
// ids against agent-options before they reach here, so we just keep the known
// groups with plausible string ids for current members and drop the rest. Stays
// agent-agnostic so this module never imports the option catalog.
//   * model/effort/permission/fast are short option ids (<= 64 chars).
//   * nickname is a swarm-scoped display name for the member (<= 80 chars).
//   * prompt is the member's per-swarm work instructions / persona (<= 4000).
const CONFIG_GROUPS = ['model', 'effort', 'permission', 'fast'];
const MAX_MEMBER_NICKNAME = 80;
const MAX_MEMBER_PROMPT = 4000;

function normalizeMemberConfigs(raw, members) {
  const out = {};
  if (!raw || typeof raw !== 'object') return out;
  const memberSet = new Set(members);
  for (const key of Object.keys(raw)) {
    if (!memberSet.has(key)) continue;
    const value = raw[key];
    if (!value || typeof value !== 'object') continue;
    const config = {};
    for (const group of CONFIG_GROUPS) {
      const id = value[group];
      if (typeof id === 'string' && id && id.length <= 64) config[group] = id;
    }
    if (typeof value.nickname === 'string') {
      const nickname = value.nickname.replace(/\s+/g, ' ').trim();
      if (nickname) config.nickname = nickname.slice(0, MAX_MEMBER_NICKNAME);
    }
    if (typeof value.prompt === 'string') {
      const prompt = value.prompt.trim();
      if (prompt) config.prompt = prompt.slice(0, MAX_MEMBER_PROMPT);
    }
    if (Object.keys(config).length > 0) out[key] = config;
  }
  return out;
}

function normalizeGroup(raw, now) {
  if (!raw || typeof raw !== 'object') return null;
  const id = validGroupId(raw.id);
  if (!id) return null;
  const members = normalizeMembers(raw.members);
  if (members.length === 0) return null;
  return {
    id,
    name: normalizeName(raw.name, 'Swarm'),
    members,
    workdir: typeof raw.workdir === 'string' ? raw.workdir : '',
    memberConfigs: normalizeMemberConfigs(raw.memberConfigs, members),
    createdAt: String(raw.createdAt || now),
    updatedAt: String(raw.updatedAt || raw.createdAt || now),
  };
}

function bucketFor(workdir) {
  const raw = store.load()[workdir];
  const list = Array.isArray(raw && raw.groups) ? raw.groups : [];
  const now = new Date().toISOString();
  const groups = [];
  const seen = new Set();
  for (const item of list) {
    const group = normalizeGroup(item, now);
    if (!group || seen.has(group.id)) continue;
    seen.add(group.id);
    groups.push(group);
  }
  groups.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  return { groups };
}

function saveBucket(workdir, bucket) {
  store.mutate((all) => {
    all[workdir] = bucket;
  });
}

function groupPayload(group) {
  return {
    id: group.id,
    name: group.name,
    members: [...group.members],
    workdir: group.workdir || '',
    memberConfigs: normalizeMemberConfigs(group.memberConfigs, group.members),
    createdAt: group.createdAt,
    updatedAt: group.updatedAt,
  };
}

function listGroups(workdir) {
  return bucketFor(workdir).groups.map(groupPayload);
}

function getGroup(workdir, groupId) {
  const id = validGroupId(groupId);
  if (!id) return null;
  const group = bucketFor(workdir).groups.find((item) => item.id === id);
  return group ? groupPayload(group) : null;
}

// Create a swarm in `workspace`. `members` must already be known-agent keys (the
// caller checks against the agent registry); here we only structurally normalize.
// `workdir` is the chosen work tree (the caller validates the path) and
// `memberConfigs` the per-member option ids (the caller normalizes them). Returns
// the new swarm, or null when members are empty or the per-workspace cap is hit.
function createGroup(workspace, rawName, members, options = {}) {
  const normalizedMembers = normalizeMembers(members);
  if (normalizedMembers.length === 0) return null;
  const bucket = bucketFor(workspace);
  if (bucket.groups.length >= MAX_GROUPS_PER_WORKDIR) return null;
  const now = new Date().toISOString();
  const group = {
    id: crypto.randomUUID(),
    name: normalizeName(rawName, `Swarm ${bucket.groups.length + 1}`),
    members: normalizedMembers,
    workdir: typeof options.workdir === 'string' ? options.workdir : '',
    memberConfigs: normalizeMemberConfigs(options.memberConfigs, normalizedMembers),
    createdAt: now,
    updatedAt: now,
  };
  bucket.groups.unshift(group);
  saveBucket(workspace, bucket);
  return groupPayload(group);
}

// Replace a swarm's members and per-member configs (keeps id/workdir/transcript).
// Returns the updated swarm, or null when it is missing or members are empty.
function setGroupMembers(workspace, groupId, members, options = {}) {
  const id = validGroupId(groupId);
  if (!id) return null;
  const normalizedMembers = normalizeMembers(members);
  if (normalizedMembers.length === 0) return null;
  const bucket = bucketFor(workspace);
  const group = bucket.groups.find((item) => item.id === id);
  if (!group) return null;
  group.members = normalizedMembers;
  group.memberConfigs = normalizeMemberConfigs(
    options.memberConfigs,
    normalizedMembers,
  );
  group.updatedAt = new Date().toISOString();
  saveBucket(workspace, bucket);
  return groupPayload(group);
}

function touchGroup(workdir, groupId) {
  const id = validGroupId(groupId);
  if (!id) return null;
  const bucket = bucketFor(workdir);
  const group = bucket.groups.find((item) => item.id === id);
  if (!group) return null;
  group.updatedAt = new Date().toISOString();
  saveBucket(workdir, bucket);
  return groupPayload(group);
}

function deleteGroup(workdir, groupId) {
  const id = validGroupId(groupId);
  if (!id) return null;
  const bucket = bucketFor(workdir);
  const index = bucket.groups.findIndex((item) => item.id === id);
  if (index === -1) return null;
  const [deleted] = bucket.groups.splice(index, 1);
  saveBucket(workdir, bucket);
  return groupPayload(deleted);
}

module.exports = {
  MAX_GROUPS_PER_WORKDIR,
  MAX_MEMBERS,
  validGroupId,
  normalizeMembers,
  listGroups,
  getGroup,
  createGroup,
  setGroupMembers,
  touchGroup,
  deleteGroup,
};
