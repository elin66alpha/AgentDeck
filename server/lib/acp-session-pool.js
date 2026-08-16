'use strict';

const { createStdioAgentPool } = require('./stdio-agent-pool');

// The ACP (Agent Client Protocol) driver, used by opencode and hermes: both
// ship an `acp` subcommand that speaks it on stdio. stdio-agent-pool.js owns the
// process, the wire and the session cap; this file is only the protocol.
//
// ACP turns are request/response — `session/prompt` resolves when the turn ends
// — and settings apply to a live session with no restart, which is why nothing
// here is fixed at open time.
const PROTOCOL_VERSION = 1;

function createAcpDriver(rpc) {
  return {
    async initialize() {
      const init = await rpc.request('initialize', {
        protocolVersion: PROTOCOL_VERSION,
        // Relay does not proxy the filesystem or terminals: the agent runs on
        // the same machine, so it uses its own.
        clientCapabilities: {
          fs: { readTextFile: false, writeTextFile: false },
          terminal: false,
        },
      });
      const caps = (init && init.agentCapabilities) || {};
      const sessionCaps = caps.sessionCapabilities || {};
      rpc.caps.loadSession = !!caps.loadSession;
      // Hermes advertises no close, so its evicted sessions are only dropped.
      rpc.caps.close = !!sessionCaps.close;
    },

    async openSession(req) {
      if (req.resumeId && rpc.caps.loadSession) {
        try {
          await rpc.request('session/load', {
            sessionId: req.resumeId,
            cwd: req.cwd,
            mcpServers: [],
          });
          return { sessionId: req.resumeId, startedNew: false };
        } catch (_err) {
          // A stored session the agent no longer has. Start a fresh one rather
          // than failing the turn — the same recovery the per-turn runner did
          // when `--session` was rejected.
        }
      }
      const created = await rpc.request('session/new', {
        cwd: req.cwd,
        mcpServers: [],
      });
      const sessionId = created && created.sessionId;
      if (!sessionId) throw new Error(`${rpc.agentKey} returned no session id`);
      return { sessionId, startedNew: !!req.resumeId };
    },

    closeSession(entry) {
      if (!rpc.caps.close) return Promise.resolve();
      return rpc.request('session/close', { sessionId: entry.sessionId });
    },

    // Model and mode changes are hot in ACP: they apply to the live session
    // with no restart, unlike the Claude pool where they are fixed at spawn.
    // An agent that rejects a value keeps running on its own default rather
    // than failing the user's turn over a setting.
    applySettings(entry, req) {
      const set = async (field, method, key) => {
        const value = req[field];
        if (!value || entry.applied[field] === value || entry.closed) return;
        try {
          await rpc.request(method, { sessionId: entry.sessionId, [key]: value });
          entry.applied[field] = value;
        } catch (_err) {
          // Left on the agent's own default.
        }
      };
      return Promise.all([
        set('modelId', 'session/set_model', 'modelId'),
        set('modeId', 'session/set_mode', 'modeId'),
      ]);
    },

    startTurn(entry, req, turn) {
      rpc
        .request('session/prompt', {
          sessionId: entry.sessionId,
          prompt: [{ type: 'text', text: String(req.prompt) }],
        })
        .then(
          (result) => turn.finish(result || { stopReason: 'end_turn' }),
          (err) => turn.fail(err),
        );
    },

    cancelTurn(entry) {
      rpc.notify('session/cancel', { sessionId: entry.sessionId });
    },

    handleMessage(msg) {
      const params = msg.params || {};
      // The agent asks us things too. Permission requests are the only one
      // Relay answers; everything else is refused explicitly so the agent never
      // hangs waiting on a reply that is not coming.
      if (msg.id !== undefined) {
        if (msg.method !== 'session/request_permission') {
          rpc.replyError(msg.id, -32601, `unsupported method: ${msg.method}`);
          return;
        }
        const entry = rpc.sessionFor(params.sessionId);
        const turn = entry && entry.turn;
        const title = (params.toolCall && params.toolCall.title) || 'tool call';
        let approve = false;
        try {
          approve = !!(turn && turn.onPermission && turn.onPermission({ title }));
        } catch (_err) {
          approve = false;
        }
        // The runner decides yes or no; picking the option that says so is
        // protocol knowledge and stays here.
        const options = Array.isArray(params.options) ? params.options : [];
        const pick = (...kinds) => {
          for (const kind of kinds) {
            const found = options.find((option) => option && option.kind === kind);
            if (found) return found.optionId;
          }
          return null;
        };
        const optionId = approve
          ? pick('allow_always', 'allow_once')
          : pick('reject_once', 'reject_always');
        rpc.reply(
          msg.id,
          optionId
            ? { outcome: { outcome: 'selected', optionId } }
            : { outcome: { outcome: 'cancelled' } },
        );
        return;
      }
      if (msg.method !== 'session/update') return;
      const entry = rpc.sessionFor(params.sessionId);
      const turn = entry && entry.turn;
      if (!turn) return;
      const update = params.update || {};
      // Only assistant text reaches the user, and it is what makes a silent
      // retry unsafe.
      if (update.sessionUpdate === 'agent_message_chunk') turn.emitted = true;
      turn.onMessage(update);
    },
  };
}

function createAcpSessionPool(options = {}) {
  return createStdioAgentPool({ ...options, driver: createAcpDriver });
}

module.exports = { createAcpSessionPool };
