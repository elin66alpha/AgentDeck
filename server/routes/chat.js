'use strict';

const express = require('express');

module.exports = function createChatRouter(ctx) {
  const {
    DEFAULT_AGENT,
    MAX_PROMPT_BYTES,
    activeRequests,
    agentRequiredOrUnknownError,
    agentTurnDependencies,
    broadcastScope,
    clearHistory,
    purgeSession,
    createChatResponder,
    finalizeStaleStreamingHistory,
    getAgent,
    listAgents,
    listChatSessions,
    markdownForConversation,
    normalizeDeviceId,
    notifyTaskCompletion,
    randomUUID,
    readHistory,
    requestWorkdir,
    resolveAgentScope,
    resolveChatSession,
    runAgentTurn,
    runningScopes,
    safeDownloadName,
    scopeChains,
    scopeKeyFor,
    searchHistory,
    sendWorkdirError,
    sessionContextKeyFor,
    sessionPayload,
    touchChatSession,
  } = ctx;
  const router = express.Router();

  router.post('/api/chat', async (req, res) => {
    const agentKey = String(req.body.agent || DEFAULT_AGENT).trim();
    const requestId = String(req.body.requestId || randomUUID()).trim();
    const prompt = String(req.body.prompt || '').trim();
    const requestedSessionId = String(req.body.sessionId || '').trim();
    const recordHistory = req.body.recordHistory !== false;
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
    const scope = resolveAgentScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
      agentError: (key) => ({ status: 400, body: { error: `unknown agent: ${key}` } }),
      beforeWorkdir: () => {
        if (!activeRequests.has(requestId)) return true;
        res.status(409).json({
          error: 'request already running',
          code: 'REQUEST_BUSY',
        });
        return false;
      },
    });
    if (!scope) return;
    const { agent, workdir, contextKey, session: chatSession, scopeKey } = scope;
    touchChatSession(contextKey, chatSession.id);

    const abortController = new AbortController();
    const historyAssistantId = `${requestId}:assistant`;
    const runState = {
      requestId,
      agent,
      session: chatSession,
      deviceId,
      scopeKey,
      scopeWorkdir: workdir,
      recordHistory,
      historyAssistantId,
      cancelled: false,
      cancelEventSent: false,
      abortController,
    };
    activeRequests.set(requestId, runState);
    const responder = createChatResponder({ req, res });

    try {
      await runAgentTurn({
        agent,
        agentKey,
        contextKey,
        dependencies: agentTurnDependencies(),
        deviceId,
        notifyTaskCompletion,
        prompt,
        recordHistory,
        requestId,
        responder,
        runState,
        scopeKey,
        session: chatSession,
        signal: abortController.signal,
        workdir,
      });
    } finally {
      activeRequests.delete(requestId);
    }
  });

  router.post('/api/chat/cancel', (req, res) => {
    const requestId = String(req.body.requestId || '').trim();
    const deviceId = normalizeDeviceId(req.get('x-device-id'));
    if (!requestId) {
      return res.status(400).json({ error: 'requestId is required' });
    }

    const runState = activeRequests.get(requestId);
    // A group round shares activeRequests but has no single agent; it is cancelled
    // through /api/group/chat/cancel, so ignore it here.
    if (!runState || runState.group) {
      return res.status(404).json({
        error: 'request not found',
        code: 'REQUEST_NOT_FOUND',
      });
    }
    // Shared sessions: any device currently in the same work directory may cancel
    // the turn, not just the device that started it.
    let workdir;
    try {
      workdir = requestWorkdir(req);
    } catch (err) {
      return sendWorkdirError(res, err);
    }
    if (runState.scopeWorkdir && runState.scopeWorkdir !== workdir) {
      return res.status(404).json({
        error: 'request not found',
        code: 'REQUEST_NOT_FOUND',
      });
    }

    runState.cancelled = true;
    if (!runState.cancelEventSent) {
      runState.cancelEventSent = true;
      broadcastScope('agent_cancelled', {
        scopeWorkdir: runState.scopeWorkdir,
        agent: runState.agent,
        session: runState.session,
        requestId,
        deviceId: runState.deviceId,
      });
    }
    runState.abortController.abort();
    return res.json({ ok: true, requestId });
  });

  // Return the stored conversation for this work directory + agent + chat session
  // so any device in the same path/session shows the same chat.
  router.get('/api/history', (req, res) => {
    const agentKey = String(req.query.agent || '').trim();
    const requestedSessionId = String(req.query.sessionId || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
      agentError: agentRequiredOrUnknownError,
    });
    if (!scope) return;
    const { agent, workdir, session: chatSession, scopeKey } = scope;
    // Only finalize a streaming bubble as stale when nothing is running OR queued
    // for this scope; a queued turn has a persisted awaiting bubble that is not
    // yet in runningScopes and must not be prematurely marked cancelled.
    if (!runningScopes.has(scopeKey) && !scopeChains.has(scopeKey)) {
      finalizeStaleStreamingHistory(scopeKey);
    }
    return res.json({
      agent: agent.key,
      workdir,
      session: sessionPayload(chatSession),
      messages: readHistory(scopeKey),
    });
  });

  router.get('/api/history/search', (req, res) => {
    const query = String(req.query.q || '').trim();
    const agentKey = String(req.query.agent || '').trim();
    if (!query) {
      return res.status(400).json({ error: 'q is required' });
    }
    if (agentKey && !getAgent(agentKey)) {
      return res.status(400).json({ error: `unknown agent: ${agentKey}` });
    }
    let workdir;
    try {
      workdir = requestWorkdir(req);
    } catch (err) {
      return sendWorkdirError(res, err);
    }
    const sessionNameFor = (matchAgentKey, sessionId) => {
      const contextKey = sessionContextKeyFor(matchAgentKey, workdir);
      const session = listChatSessions(contextKey).sessions.find(
        (item) => item.id === sessionId,
      );
      return session ? session.name : sessionId;
    };
    const matches = searchHistory({
      workdir,
      query,
      agentKey,
      sessionNameFor,
    });
    return res.json({ workdir, query, matches });
  });

  router.get('/api/history/export', (req, res) => {
    const agentKey = String(req.query.agent || '').trim();
    const requestedSessionId = String(req.query.sessionId || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
      agentError: agentRequiredOrUnknownError,
    });
    if (!scope) return;
    const { agent, session: chatSession, scopeKey } = scope;
    if (!runningScopes.has(scopeKey) && !scopeChains.has(scopeKey)) {
      finalizeStaleStreamingHistory(scopeKey);
    }
    const exportedAt = new Date().toISOString();
    const markdown = markdownForConversation({
      agentLabel: agent.label,
      sessionName: chatSession.name,
      messages: readHistory(scopeKey),
      exportedAt,
    });
    const fileName = `${safeDownloadName(agent.key)}-${safeDownloadName(chatSession.name, 'session')}.md`;
    return res.json({
      agent: agent.key,
      session: sessionPayload(chatSession),
      fileName,
      markdown,
    });
  });

  // Clear one chat session's history plus resumable CLI session so the next message
  // starts a new machine-side conversation. This does not touch files on disk.
  router.post('/api/session/clear', async (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const requestedSessionId = String(req.body.sessionId || '').trim();
    let workdir;
    try {
      workdir = requestWorkdir(req);
    } catch (err) {
      return sendWorkdirError(res, err);
    }
    if (agentKey) {
      const agent = getAgent(agentKey);
      if (!agent) {
        return res.status(400).json({ error: `unknown agent: ${agentKey}` });
      }
      const contextKey = sessionContextKeyFor(agent.key, workdir);
      const sessions = listChatSessions(contextKey).sessions;
      const chatSession = requestedSessionId
        ? sessions.find((session) => session.id === requestedSessionId)
        : resolveChatSession(contextKey, '');
      if (!chatSession) {
        return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
      }
      const scopeKey = scopeKeyFor(agent.key, workdir, chatSession.id);
      if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
        return res.status(409).json({
          error: 'session has a running turn',
          code: 'SESSION_BUSY',
        });
      }
      const cleared = await purgeSession(scopeKey, {
        agentKey: agent.key,
        workdir,
      });
      clearHistory(scopeKey);
      touchChatSession(contextKey, chatSession.id);
      return res.json({
        ok: true,
        agent: agentKey,
        workdir,
        session: sessionPayload(chatSession),
        cleared,
      });
    }
    let cleared = 0;
    for (const agent of listAgents()) {
      const contextKey = sessionContextKeyFor(agent.key, workdir);
      for (const chatSession of listChatSessions(contextKey).sessions) {
        const scopeKey = scopeKeyFor(agent.key, workdir, chatSession.id);
        if (await purgeSession(scopeKey, { agentKey: agent.key, workdir })) {
          cleared += 1;
        }
        clearHistory(scopeKey);
      }
    }
    return res.json({ ok: true, workdir, cleared });
  });

  return router;
};
