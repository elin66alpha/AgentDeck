'use strict';

const express = require('express');

const {
  listGroups,
  getGroup,
  createGroup,
  setGroupMembers,
  touchGroup,
  deleteGroup,
} = require('../lib/groups');
const {
  parseMentions,
  deltaSince,
  buildGroupPrompt,
} = require('../lib/group-turn');
const { normalizeSettings } = require('../lib/agent-options');

// Multi-agent group chat: one human, several agents, one canonical transcript.
// The orchestrator reuses the single-agent turn pipeline (runAgentTurn) once per
// summoned member, serialized on the group's scope so exactly one agent holds the
// floor at a time. Each member runs against its OWN resumable CLI session (its
// private memory) and is fed only the delta since it last spoke (see
// docs/group-chat.md, "plan B"). The group transcript lives under a dedicated
// scope agent key so it never mixes with any member's solo conversation.
const GROUP_SCOPE_PREFIX = 'group:';
const HUMAN_AUTHOR = 'human';

// A member's reply can summon other members, so one human message can run
// several waves of turns. Cap how many of those agent-driven waves follow the
// human's, since two members that keep naming each other would otherwise talk
// (and bill) forever. 0 restores human-only summoning.
const DEFAULT_MAX_MENTION_HOPS = 3;

function maxMentionHops(env = process.env) {
  const raw = Number.parseInt(env.RELAY_SWARM_MAX_HOPS ?? '', 10);
  if (!Number.isFinite(raw) || raw < 0) return DEFAULT_MAX_MENTION_HOPS;
  return Math.min(raw, 20);
}

function wantsStream(req) {
  return String(req.get('accept') || '')
    .toLowerCase()
    .includes('text/event-stream');
}

function writeSse(res, type, payload) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
  } catch (_err) {
    // The client may have closed the tab while the round keeps running.
  }
}

function endSse(res) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.end();
  } catch (_err) {
    // Already gone; the server-side round still finishes.
  }
}

// A responder shared across every agent turn in one round. Unlike the single-chat
// responder it does NOT end the stream after each agent (final()), so the route
// can close it once the whole round drains. Non-streaming requests get one JSON
// reply from the route after the loop instead.
function createRoundResponder(res, streaming) {
  let opened = false;
  return {
    streaming,
    ready(requestId) {
      if (!streaming || opened) return;
      opened = true;
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
      });
      writeSse(res, 'ready', { ok: true, requestId });
    },
    event(type, payload) {
      if (!streaming) return false;
      writeSse(res, type, payload);
      return true;
    },
    async fallbackText() {},
    final(reply) {
      if (streaming) writeSse(res, 'agent_done', reply);
    },
    cancelled(payload) {
      if (streaming) writeSse(res, 'agent_cancelled', payload);
    },
    authError(payload) {
      if (streaming) writeSse(res, 'agent_error', payload);
    },
    error(payload) {
      if (streaming) writeSse(res, 'agent_error', payload);
    },
  };
}

module.exports = function createGroupRouter(ctx) {
  const {
    MAX_PROMPT_BYTES,
    activeRequests,
    agentTurnDependencies,
    clearHistory,
    purgeSession,
    finalizeStaleStreamingHistory,
    getAgent,
    normalizeDeviceId,
    notifyTaskCompletion,
    randomUUID,
    readHistory,
    requestWorkdir,
    runAgentTurn,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sendEvent,
    sendWorkdirError,
    sessionContextKeyFor,
    upsertHistoryMessage,
    validateWorkdir,
  } = ctx;
  const router = express.Router();
  const maxHops = maxMentionHops();

  const groupScopeKeyFor = (workdir, groupId) =>
    sessionContextKeyFor(`${GROUP_SCOPE_PREFIX}${groupId}`, workdir);
  // A member's private resumable CLI session for this swarm (keeps its own memory,
  // separate from the member's solo Main chat in the same work tree).
  const memberSessionKeyFor = (workdir, groupId, memberKey) =>
    scopeKeyFor(memberKey, workdir, groupId);
  const labelFor = (agentKey) => {
    const agent = getAgent(agentKey);
    return agent ? agent.label : agentKey;
  };

  // The work tree a swarm runs in: its pinned `workdir`, falling back to the
  // workspace it was created in for swarms saved before work-tree selection.
  const runWorkdirOf = (group, workspace) => group.workdir || workspace;

  function resolveWorkdir(req, res) {
    try {
      return requestWorkdir(req);
    } catch (err) {
      sendWorkdirError(res, err);
      return null;
    }
  }

  // The work tree chosen for a new swarm: an explicit, existing directory or the
  // workspace when none is given. Returns null (after sending an error) when the
  // path is set but invalid, so the caller bails out.
  function resolveWorkTree(res, rawPath, workspace) {
    const raw = String(rawPath || '').trim();
    if (!raw) return workspace;
    try {
      return validateWorkdir(raw, { create: false }).dir;
    } catch (err) {
      sendWorkdirError(res, err);
      return null;
    }
  }

  // Per-member config: model/effort/permission/fast normalized for that
  // agent (unknown ids fall back to defaults), plus the free-text swarm-scoped
  // `nickname` and `prompt` passed through (groups.js bounds their length). Only
  // current members are kept, so a config can never reference a dropped member.
  function normalizeConfigs(rawConfigs, members) {
    const out = {};
    if (!rawConfigs || typeof rawConfigs !== 'object') return out;
    for (const memberKey of members) {
      const raw = rawConfigs[memberKey];
      if (raw && typeof raw === 'object') {
        const config = normalizeSettings(memberKey, raw);
        if (typeof raw.nickname === 'string') config.nickname = raw.nickname;
        if (typeof raw.prompt === 'string') config.prompt = raw.prompt;
        out[memberKey] = config;
      }
    }
    return out;
  }

  // Members the caller asked for, narrowed to agents that actually exist on this
  // host. Unknown agent keys are dropped so a group can never reference a runner
  // that isn't installed.
  function knownMembers(rawMembers) {
    const list = Array.isArray(rawMembers) ? rawMembers : [];
    return list.map((m) => String(m || '').trim()).filter((m) => m && getAgent(m));
  }

  router.get('/api/groups', (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    return res.json({ workdir, groups: listGroups(workdir) });
  });

  router.post('/api/groups', (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const members = knownMembers(req.body.members);
    if (members.length === 0) {
      return res
        .status(400)
        .json({ error: 'at least one known agent member is required', code: 'GROUP_NO_MEMBERS' });
    }
    const workTree = resolveWorkTree(res, req.body.workdir, workdir);
    if (workTree === null) return undefined;
    const group = createGroup(workdir, req.body.name, members, {
      workdir: workTree,
      memberConfigs: normalizeConfigs(req.body.configs, members),
    });
    if (!group) {
      return res
        .status(409)
        .json({ error: 'too many swarms in this workspace', code: 'GROUP_LIMIT' });
    }
    return res.json({ ok: true, workdir, group, groups: listGroups(workdir) });
  });

  router.post('/api/groups/members', (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const members = knownMembers(req.body.members);
    if (members.length === 0) {
      return res
        .status(400)
        .json({ error: 'at least one known agent member is required', code: 'GROUP_NO_MEMBERS' });
    }
    const group = setGroupMembers(workdir, groupId, members, {
      memberConfigs: normalizeConfigs(req.body.configs, members),
    });
    if (!group) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    return res.json({ ok: true, workdir, group, groups: listGroups(workdir) });
  });

  router.post('/api/groups/delete', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const group = getGroup(workdir, groupId);
    if (!group) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const runWorkdir = runWorkdirOf(group, workdir);
    const scopeKey = groupScopeKeyFor(runWorkdir, group.id);
    if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
      return res.status(409).json({ error: 'group has a running turn', code: 'GROUP_BUSY' });
    }
    deleteGroup(workdir, group.id);
    clearHistory(scopeKey);
    for (const memberKey of group.members) {
      await purgeSession(memberSessionKeyFor(runWorkdir, group.id, memberKey), {
        agentKey: memberKey,
        workdir: runWorkdir,
      });
    }
    return res.json({ ok: true, workdir, groups: listGroups(workdir) });
  });

  router.get('/api/group/history', (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.query.groupId || '').trim();
    const group = getGroup(workdir, groupId);
    if (!group) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const scopeKey = groupScopeKeyFor(runWorkdirOf(group, workdir), group.id);
    if (!runningScopes.has(scopeKey) && !scopeChains.has(scopeKey)) {
      finalizeStaleStreamingHistory(scopeKey);
    }
    return res.json({ workdir, group, messages: readHistory(scopeKey) });
  });

  // Reset a swarm's transcript and every member's forked CLI session, keeping the
  // swarm itself. The next message starts the conversation afresh.
  router.post('/api/group/clear', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const group = getGroup(workdir, groupId);
    if (!group) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const runWorkdir = runWorkdirOf(group, workdir);
    const scopeKey = groupScopeKeyFor(runWorkdir, group.id);
    if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
      return res.status(409).json({ error: 'group has a running turn', code: 'GROUP_BUSY' });
    }
    clearHistory(scopeKey);
    for (const memberKey of group.members) {
      await purgeSession(memberSessionKeyFor(runWorkdir, group.id, memberKey), {
        agentKey: memberKey,
        workdir: runWorkdir,
      });
    }
    return res.json({ ok: true, workdir, group });
  });

  router.post('/api/group/chat/cancel', (req, res) => {
    const requestId = String(req.body.requestId || '').trim();
    if (!requestId) {
      return res.status(400).json({ error: 'requestId is required' });
    }
    const runState = activeRequests.get(requestId);
    if (!runState || !runState.group) {
      return res.status(404).json({ error: 'request not found', code: 'REQUEST_NOT_FOUND' });
    }
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    // Any device in the same workdir may cancel the round (shared conversation).
    if (runState.scopeWorkdir && runState.scopeWorkdir !== workdir) {
      return res.status(404).json({ error: 'request not found', code: 'REQUEST_NOT_FOUND' });
    }
    runState.cancelled = true;
    if (!runState.cancelEventSent) {
      runState.cancelEventSent = true;
      sendEvent('group_cancelled', {
        scopeWorkdir: runState.scopeWorkdir,
        groupId: runState.group.id,
        requestId,
        deviceId: runState.deviceId,
        createdAt: new Date().toISOString(),
      });
    }
    runState.abortController.abort();
    return res.json({ ok: true, requestId });
  });

  router.post('/api/group/chat', async (req, res) => {
    const groupId = String(req.body.groupId || '').trim();
    const requestId = String(req.body.requestId || randomUUID()).trim();
    const prompt = String(req.body.prompt || '').trim();
    const deviceId = normalizeDeviceId(req.get('x-device-id'));
    if (!prompt) {
      return res.status(400).json({ error: 'prompt is required' });
    }
    if (Buffer.byteLength(prompt, 'utf8') > MAX_PROMPT_BYTES) {
      return res
        .status(413)
        .json({ error: 'prompt exceeds the size limit', code: 'PROMPT_TOO_LARGE' });
    }
    if (activeRequests.has(requestId)) {
      return res.status(409).json({ error: 'request already running', code: 'REQUEST_BUSY' });
    }
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const group = getGroup(workdir, groupId);
    if (!group) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }

    // History, member sessions and the agents themselves all run in the swarm's
    // own work tree; the workspace stays the cancel/event addressing key so any
    // device that can see the swarm can cancel the round.
    const runWorkdir = runWorkdirOf(group, workdir);
    const scopeKey = groupScopeKeyFor(runWorkdir, group.id);
    // A member's display name inside this swarm: its user-set nickname when
    // present, otherwise the agent's default label. Used for @mention matching,
    // the speaker labels in each prompt, and the recorded message attribution so
    // a renamed member reads consistently everywhere.
    const groupLabelFor = (agentKey) => {
      const nickname = group.memberConfigs[agentKey] &&
        group.memberConfigs[agentKey].nickname;
      return (typeof nickname === 'string' && nickname) || labelFor(agentKey);
    };
    const mentions = parseMentions(prompt, group.members, groupLabelFor);
    const abortController = new AbortController();
    const runState = {
      requestId,
      group: { id: group.id, name: group.name },
      session: { id: group.id, name: group.name },
      deviceId,
      scopeKey,
      scopeWorkdir: workdir,
      cancelled: false,
      cancelEventSent: false,
      abortController,
    };
    activeRequests.set(requestId, runState);
    const responder = createRoundResponder(res, wantsStream(req));
    responder.ready(requestId);

    // Record the human message once per round (not once per summoned agent), then
    // mirror it to every device in the workdir so the transcript stays shared.
    const createdAt = new Date().toISOString();
    const humanMessageId = `${requestId}:human`;
    upsertHistoryMessage(scopeKey, {
      id: humanMessageId,
      role: 'user',
      content: prompt,
      agent: HUMAN_AUTHOR,
      createdAt,
      metadata: {
        author: HUMAN_AUTHOR,
        summonedBy: HUMAN_AUTHOR,
        groupId: group.id,
        groupName: group.name,
        mentions,
      },
    });
    sendEvent('group_message', {
      scopeWorkdir: workdir,
      groupId: group.id,
      requestId,
      deviceId,
      mentions,
      message: {
        id: humanMessageId,
        role: 'user',
        author: HUMAN_AUTHOR,
        content: prompt,
        createdAt,
      },
      createdAt,
    });

    const base = agentTurnDependencies();
    // Mark the group scope busy for the whole round. Members serialize on their
    // own session keys (so they run concurrently), so this group scope key is what
    // the delete/clear/history routes consult to tell the round is still running.
    runningScopes.add(scopeKey);

    // Everyone this member is allowed to hand the floor to. Empty when
    // agent-to-agent summoning is off, so the prompt never offers what the
    // orchestrator would then ignore.
    const rosterFor = (memberKey) =>
      maxHops === 0
        ? []
        : group.members
            .filter((key) => key !== memberKey)
            .map((key) => ({ key, label: groupLabelFor(key) }));

    // Freeze every summoned member's prompt up front, from one snapshot taken at
    // the start of the wave, so a member's prompt can never absorb a sibling's
    // reply even as those replies stream into the shared transcript once the
    // turns start running. (The next wave snapshots again, so it does see them.)
    const planWave = (summons, wave) => {
      const snapshot = readHistory(scopeKey);
      return summons
        .map(({ memberKey, summonedBy }, index) => {
          const memberAgent = getAgent(memberKey);
          if (!memberAgent) return null;
          const memberSessionKey = memberSessionKeyFor(runWorkdir, group.id, memberKey);
          // Plan B: feed this member only what happened since it last spoke, each
          // line labeled with its speaker. Its own resumable session has the rest.
          const delta = deltaSince(snapshot, memberKey);
          const memberConfig = group.memberConfigs[memberKey] || {};
          const groupPrompt = buildGroupPrompt({
            selfLabel: groupLabelFor(memberKey),
            persona: memberConfig.prompt,
            delta,
            labelFor: groupLabelFor,
            roster: rosterFor(memberKey),
            maxBytes: Math.max(1024, MAX_PROMPT_BYTES - 1024),
          });
          return {
            memberKey,
            memberAgent,
            memberSessionKey,
            groupPrompt,
            summonedBy,
            turnRequestId: `${requestId}.${wave}.${index}.${memberKey}`,
          };
        })
        .filter(Boolean);
    };

    // Who the replies of a finished wave handed the floor to. A member never
    // summons itself (that would never terminate), and is summoned once per wave
    // however many siblings named it — it sees all of them in its next delta.
    // Failed and cancelled turns are skipped: their recorded content is an error
    // message, not something an agent chose to say.
    const nextSummons = (results) => {
      const seen = new Set();
      const out = [];
      for (const result of results) {
        if (!result || result.status !== 'done') continue;
        const summoned = parseMentions(result.content, group.members, groupLabelFor);
        for (const memberKey of summoned) {
          if (memberKey === result.agent || seen.has(memberKey)) continue;
          seen.add(memberKey);
          out.push({ memberKey, summonedBy: result.agent });
        }
      }
      return out;
    };

    // One summoned member's turn. The assistant placeholder is recorded
    // synchronously (before the first await), so kicking these off in mention
    // order keeps the transcript ordered even though replies arrive in parallel.
    const runMember = async ({
      memberKey,
      memberAgent,
      memberSessionKey,
      groupPrompt,
      summonedBy,
      turnRequestId,
    }) => {
      const dependencies = {
        ...base,
        // Tag every shared-stream event with the group so only clients viewing
        // this group react to it.
        broadcastScope: (type, payload) =>
          base.broadcastScope(type, { ...payload, groupId: group.id }),
        // The swarm pins each member's model/effort/permission/fast itself, so use
        // its config instead of the member's solo-chat agent-settings store.
        getSettings: (agentKey) =>
          normalizeSettings(agentKey, group.memberConfigs[agentKey] || {}),
        // History lives under the group scope, but the CLI must resume the
        // member's own private group session — not the group scope key.
        runAgent: (agentKey, p, onEvent, opts) =>
          base.runAgent(agentKey, p, onEvent, { ...opts, sessionKey: memberSessionKey }),
      };
      const result = await runAgentTurn({
        agent: memberAgent,
        agentKey: memberKey,
        contextKey: sessionContextKeyFor(memberKey, runWorkdir),
        // Serialize each member only against its own group session — not the
        // shared group scope — so members summoned together run in parallel while
        // their replies still land in the one group transcript (scopeKey).
        concurrencyKey: memberSessionKey,
        dependencies,
        deviceId,
        historyMetadata: {
          author: memberKey,
          // Record the swarm-scoped display name so the transcript attributes the
          // reply to the member's nickname (falls back to the agent label).
          agentLabel: groupLabelFor(memberKey),
          summonedBy,
          groupId: group.id,
          groupName: group.name,
        },
        notifyTaskCompletion,
        prompt: groupPrompt,
        recordHistory: true,
        recordUserMessage: false,
        requestId: turnRequestId,
        responder,
        runState,
        scopeKey,
        session: { id: group.id, name: group.name },
        signal: abortController.signal,
        workdir: runWorkdir,
      });
      return {
        agent: memberKey,
        status: result && result.status,
        summonedBy,
        content: (result && result.content) || '',
      };
    };

    const turns = [];
    try {
      // The human's mentions open the round; each wave's replies can summon the
      // next, up to maxHops waves after the human's.
      let summons = mentions.map((memberKey) => ({
        memberKey,
        summonedBy: HUMAN_AUTHOR,
      }));
      for (let wave = 0; summons.length > 0 && !runState.cancelled; wave += 1) {
        const settled = await Promise.all(
          planWave(summons, wave).map((plan) => runMember(plan)),
        );
        for (const result of settled) {
          if (result) turns.push({ agent: result.agent, status: result.status });
        }
        summons = wave >= maxHops ? [] : nextSummons(settled);
      }
    } finally {
      runningScopes.delete(scopeKey);
      activeRequests.delete(requestId);
    }

    touchGroup(workdir, group.id);
    const summary = {
      ok: true,
      requestId,
      groupId: group.id,
      cancelled: runState.cancelled,
      turns,
    };
    // Broadcast the round's end on the shared stream so every device viewing this
    // group reloads the authoritative transcript — important for agents that emit
    // no streaming deltas (their final reply isn't on the live stream) and for
    // other devices, which never see the POST response.
    sendEvent('group_done', {
      ...summary,
      scopeWorkdir: workdir,
      deviceId,
      createdAt: new Date().toISOString(),
    });
    if (responder.streaming) {
      writeSse(res, 'group_done', { ...summary, createdAt: new Date().toISOString() });
      endSse(res);
      return undefined;
    }
    return res.json(summary);
  });

  return router;
};
