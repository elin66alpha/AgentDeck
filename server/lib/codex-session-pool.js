'use strict';

const { createStdioAgentPool } = require('./stdio-agent-pool');

// The Codex app-server driver. stdio-agent-pool.js owns the process, the wire
// and the session cap; this file is only the protocol.
//
// `codex app-server` is JSON-RPC 2.0 on stdio like ACP, but its turn lifecycle
// is different in one way that shapes this file: `turn/start` returns as soon
// as the turn is *accepted*, and the turn ends later with a `turn/completed`
// notification. So the request only records the turn id (which cancellation
// needs) and the pool's turn is settled from the notification stream.
//
// Everything Relay configures except the sandbox can be set per turn, so a
// settings change never reopens anything. The sandbox is fixed when a thread is
// opened, which is what the runner passes as `fixedKey`.
const CLIENT_INFO = { name: 'relay', title: 'Relay', version: '1' };

// The decision vocabulary differs per approval request, and answering with the
// wrong token reads as a denial, so each is spelled out rather than guessed.
const APPROVAL_DECISIONS = {
  'item/commandExecution/requestApproval': { yes: 'accept', no: 'decline' },
  'item/fileChange/requestApproval': { yes: 'accept', no: 'decline' },
  execCommandApproval: { yes: 'approved', no: 'abort' },
  applyPatchApproval: { yes: 'approved', no: 'abort' },
};

function approvalTitle(params) {
  const command = params.command || (params.toolCall && params.toolCall.title);
  if (Array.isArray(command)) return command.join(' ');
  return command || params.itemId || 'tool call';
}

function threadOptions(req) {
  const options = { cwd: req.cwd };
  if (req.sandbox) options.sandbox = req.sandbox;
  if (req.approvalPolicy) options.approvalPolicy = req.approvalPolicy;
  if (req.model) options.model = req.model;
  if (req.serviceTier) options.serviceTier = req.serviceTier;
  return options;
}

function createCodexDriver(rpc) {
  // Only the turn/start response carries the id, so a turn cancelled before it
  // arrives has nothing to interrupt yet — interrupt() is called again from
  // there. Without that, cancelling early would leave codex running the turn
  // until the pool gave up and dropped the whole session.
  function interrupt(entry, turn) {
    if (!turn.turnId || turn.interrupted) return;
    turn.interrupted = true;
    rpc
      .request('turn/interrupt', {
        threadId: entry.sessionId,
        turnId: turn.turnId,
      })
      .catch(() => {
        // The pool's grace timer drops the session if this does not land.
      });
  }

  return {
    initialize() {
      return rpc.request('initialize', { clientInfo: CLIENT_INFO });
    },

    async openSession(req) {
      if (req.resumeId) {
        try {
          const resumed = await rpc.request('thread/resume', {
            threadId: req.resumeId,
            ...threadOptions(req),
          });
          return { sessionId: resumed.thread.id, startedNew: false };
        } catch (_err) {
          // A stored thread codex no longer has. Start a fresh one rather than
          // failing the turn — the same recovery the per-turn runner did when
          // `exec resume` rejected the id.
        }
      }
      const started = await rpc.request('thread/start', threadOptions(req));
      const sessionId = started && started.thread && started.thread.id;
      if (!sessionId) throw new Error('codex returned no thread id');
      return { sessionId, startedNew: !!req.resumeId };
    },

    closeSession(entry) {
      // Releases codex's live state for the thread; the transcript stays on
      // disk so the next turn can resume it.
      return rpc.request('thread/unsubscribe', { threadId: entry.sessionId });
    },

    startTurn(entry, req, turn) {
      const params = {
        threadId: entry.sessionId,
        input: [{ type: 'text', text: String(req.prompt) }],
        cwd: req.cwd,
      };
      if (req.model) params.model = req.model;
      if (req.effort) params.effort = req.effort;
      if (req.approvalPolicy) params.approvalPolicy = req.approvalPolicy;
      if (req.serviceTier) params.serviceTier = req.serviceTier;
      rpc.request('turn/start', params).then(
        (result) => {
          // Only the id: completion arrives as a notification.
          turn.turnId = result && result.turn && result.turn.id;
          if (turn.cancelled) interrupt(entry, turn);
        },
        (err) => turn.fail(err),
      );
    },

    cancelTurn: interrupt,

    deleteSession(sessionId) {
      return rpc
        .request('thread/delete', { threadId: sessionId })
        .then(() => true, () => false);
    },

    // Branch a thread into a new one that inherits its memory without writing
    // back to it — how /btw asks a side question without disturbing the main
    // task. Relay used to do this by copying rows and rollout files inside
    // codex's private SQLite state; this is the supported operation for it.
    async fork(threadId, cwd) {
      const forked = await rpc.request('thread/fork', { threadId, cwd });
      const id = forked && forked.thread && forked.thread.id;
      if (!id) throw new Error('codex returned no forked thread id');
      return id;
    },

    handleMessage(msg) {
      const params = msg.params || {};
      // Every Relay tier runs with approvalPolicy "never", so these should not
      // arrive at all — but an unanswered request would hang the turn forever,
      // so they are answered from the runner's policy anyway. Anything else is
      // refused explicitly rather than answered with a shape codex cannot read.
      if (msg.id !== undefined) {
        const decisions = APPROVAL_DECISIONS[msg.method];
        if (!decisions) {
          rpc.replyError(msg.id, -32601, `unsupported method: ${msg.method}`);
          return;
        }
        const entry = rpc.sessionFor(params.threadId);
        const turn = entry && entry.turn;
        let approve = false;
        try {
          approve = !!(
            turn &&
            turn.onPermission &&
            turn.onPermission({ title: approvalTitle(params) })
          );
        } catch (_err) {
          approve = false;
        }
        rpc.reply(msg.id, { decision: approve ? decisions.yes : decisions.no });
        return;
      }

      const entry = rpc.sessionFor(params.threadId);
      const turn = entry && entry.turn;
      if (!turn) return;
      switch (msg.method) {
        case 'item/agentMessage/delta':
          // Assistant text is the only thing that reaches the user, and it is
          // what makes a silent retry unsafe.
          turn.emitted = true;
          turn.onMessage({ type: 'delta', text: params.delta, itemId: params.itemId });
          return;
        case 'item/completed':
          turn.onMessage({ type: 'item', item: params.item || {} });
          return;
        case 'turn/completed': {
          const status = (params.turn && params.turn.status) || 'completed';
          turn.finish({ stopReason: status, turn: params.turn });
          return;
        }
        case 'error':
          // A retryable error is codex telling us it is still working.
          if (params.willRetry) return;
          turn.fail(new Error((params.error && params.error.message) || 'codex error'));
          return;
        default:
      }
    },
  };
}

function createCodexSessionPool(options = {}) {
  return createStdioAgentPool({ ...options, driver: createCodexDriver });
}

module.exports = { createCodexSessionPool };
