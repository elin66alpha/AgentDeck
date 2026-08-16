'use strict';

const express = require('express');

// The /btw sidekick. A side question that inherits the main conversation's
// memory but never touches the main task. Each supported CLI forks or clones
// its own native session storage into a dedicated `btw:<agent>` scope so the
// side chat never writes back to the main conversation.
const BTW_SUPPORTED = new Set(['claude', 'codex']);

function btwScopeAgent(agentKey) {
  return `btw:${agentKey}`;
}

module.exports = function createBtwRouter(ctx) {
  const {
    MAX_PROMPT_BYTES,
    activeRequests,
    agentTurnDependencies,
    clearHistory,
    purgeSession,
    createChatResponder,
    finalizeStaleStreamingHistory,
    normalizeDeviceId,
    randomUUID,
    readHistory,
    resolveAgentScope,
    runAgentTurn,
    runBtwAgent,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sessionPayload,
  } = ctx;
  const router = express.Router();

  // Resolve the main conversation scope plus the derived side-chat scope.
  function resolveBtwScope(req, res, { agentKey, sessionId }) {
    if (!BTW_SUPPORTED.has(agentKey)) {
      res.status(400).json({
        error: `btw is not available for ${agentKey || 'this agent'}`,
        code: 'BTW_UNSUPPORTED',
      });
      return null;
    }
    const scope = resolveAgentScope(req, res, {
      agentKey,
      sessionId,
      agentError: (key) => ({
        status: 400,
        body: { error: `unknown agent: ${key}` },
      }),
    });
    if (!scope) return null;
    // The side chat gets its own scope for history + its own fork/session.
    const btwScopeKey = scopeKeyFor(
      btwScopeAgent(agentKey),
      scope.workdir,
      scope.session.id,
    );
    return { ...scope, mainSessionKey: scope.scopeKey, btwScopeKey };
  }

  router.post('/api/btw', async (req, res) => {
    const agentKey = String(req.body.agent || 'claude').trim();
    const requestId = String(req.body.requestId || randomUUID()).trim();
    const prompt = String(req.body.prompt || '').trim();
    const requestedSessionId = String(req.body.sessionId || '').trim();
    const deviceId = normalizeDeviceId(req.get('x-device-id'));
    if (!prompt) {
      return res.status(400).json({ error: 'prompt is required' });
    }
    if (Buffer.byteLength(prompt, 'utf8') > MAX_PROMPT_BYTES) {
      return res.status(413).json({
        error: 'prompt exceeds the size limit',
        code: 'PROMPT_TOO_LARGE',
      });
    }
    if (activeRequests.has(requestId)) {
      return res
        .status(409)
        .json({ error: 'request already running', code: 'REQUEST_BUSY' });
    }
    const scope = resolveBtwScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
    });
    if (!scope) return;
    const { agent, workdir, contextKey, session, mainSessionKey, btwScopeKey } =
      scope;

    const abortController = new AbortController();
    const runState = {
      requestId,
      agent,
      session,
      deviceId,
      scopeKey: btwScopeKey,
      scopeWorkdir: workdir,
      recordHistory: true,
      historyAssistantId: `${requestId}:assistant`,
      cancelled: false,
      cancelEventSent: false,
      abortController,
    };
    activeRequests.set(requestId, runState);
    const responder = createChatResponder({ req, res });

    // Reuse the standard turn pipeline (SSE streaming, segmented history,
    // cancellation) but swap the runner for the forking sidekick. The side chat
    // is delivered only on this request's SSE stream, never on the shared scope
    // stream — otherwise the main chat on this (or another) device would mistake
    // the sidekick's events for activity on the main conversation and start
    // mirroring it.
    const baseDependencies = agentTurnDependencies();
    const dependencies = {
      ...baseDependencies,
      broadcastScope: () => {},
      runAgent: (_agentKey, p, onEvent, opts) =>
        runBtwAgent(agentKey, p, onEvent, {
          mainSessionKey,
          btwSessionKey: opts.sessionKey,
          signal: opts.signal,
          workdir: opts.workdir,
          settings: opts.settings,
        }),
    };

    try {
      await runAgentTurn({
        agent,
        agentKey,
        contextKey,
        dependencies,
        deviceId,
        prompt,
        recordHistory: true,
        requestId,
        responder,
        runState,
        scopeKey: btwScopeKey,
        session,
        signal: abortController.signal,
        workdir,
      });
    } finally {
      activeRequests.delete(requestId);
    }
  });

  // The side conversation for the current main session.
  router.get('/api/btw/history', (req, res) => {
    const agentKey = String(req.query.agent || 'claude').trim();
    const requestedSessionId = String(req.query.sessionId || '').trim();
    const scope = resolveBtwScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
    });
    if (!scope) return;
    const { session, btwScopeKey } = scope;
    if (!runningScopes.has(btwScopeKey) && !scopeChains.has(btwScopeKey)) {
      finalizeStaleStreamingHistory(btwScopeKey);
    }
    return res.json({
      agent: agentKey,
      session: sessionPayload(session),
      messages: readHistory(btwScopeKey),
    });
  });

  // Reset the side chat: drop its history and forked session so the next
  // question forks the main conversation afresh. Resolve the scope the same way
  // as /api/btw and /api/btw/history (off the canonical session id) so we always
  // clear the exact key those wrote to.
  router.post('/api/btw/clear', async (req, res) => {
    const agentKey = String(req.body.agent || 'claude').trim();
    const requestedSessionId = String(req.body.sessionId || '').trim();
    const scope = resolveBtwScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
    });
    if (!scope) return;
    const { btwScopeKey, workdir } = scope;
    if (runningScopes.has(btwScopeKey)) {
      return res
        .status(409)
        .json({ error: 'a side question is running', code: 'SESSION_BUSY' });
    }
    // The side chat is its own forked session, so resetting it deletes that
    // fork's transcript rather than leaving an unreachable one behind.
    await purgeSession(btwScopeKey, {
      agentKey: `btw:${agentKey}`,
      workdir,
    });
    clearHistory(btwScopeKey);
    return res.json({ ok: true });
  });

  return router;
};
