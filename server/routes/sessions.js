'use strict';

const express = require('express');

module.exports = function createSessionsRouter(ctx) {
  const {
    LEGACY_SESSION_ID,
    MAX_SESSIONS,
    agentPayload,
    agentRequiredOrUnknownError,
    clearHistory,
    purgeSession,
    createChatSession,
    deleteChatSession,
    listChatSessions,
    resolveAgentScope,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    setActiveChatSession,
  } = ctx;
  const router = express.Router();

  router.get('/api/sessions', (req, res) => {
    const agentKey = String(req.query.agent || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    return res.json({
      ok: true,
      agent: agentPayload(agent),
      workdir,
      ...listChatSessions(contextKey),
    });
  });

  router.post('/api/sessions', (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const created = createChatSession(contextKey, req.body.name);
    if (!created) {
      return res.status(409).json({
        error: `session limit reached (max ${MAX_SESSIONS})`,
        code: 'SESSION_LIMIT_REACHED',
      });
    }
    return res.json({
      ok: true,
      agent: agentPayload(agent),
      workdir,
      ...created,
    });
  });

  router.post('/api/sessions/active', (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const sessionId = String(req.body.sessionId || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
      beforeWorkdir: () => {
        if (sessionId) return true;
        res.status(400).json({ error: 'sessionId is required' });
        return false;
      },
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const result = setActiveChatSession(contextKey, sessionId);
    if (!result) {
      return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
    }
    return res.json({
      ok: true,
      agent: agentPayload(agent),
      workdir,
      ...result,
    });
  });

  router.post('/api/sessions/delete', async (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const sessionId = String(req.body.sessionId || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
      beforeWorkdir: () => {
        if (!sessionId) {
          res.status(400).json({ error: 'sessionId is required' });
          return false;
        }
        if (sessionId === LEGACY_SESSION_ID) {
          res.status(400).json({
            error: 'the default session cannot be deleted',
            code: 'SESSION_PROTECTED',
          });
          return false;
        }
        return true;
      },
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const existing = listChatSessions(contextKey).sessions.find(
      (session) => session.id === sessionId,
    );
    if (!existing) {
      return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
    }
    const scopeKey = scopeKeyFor(agent.key, workdir, sessionId);
    if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
      return res.status(409).json({
        error: 'session has a running turn',
        code: 'SESSION_BUSY',
      });
    }
    const result = deleteChatSession(contextKey, sessionId);
    await purgeSession(scopeKey, { agentKey: agent.key, workdir });
    clearHistory(scopeKey);
    // The /btw side chat is a fork of this conversation and has a transcript of
    // its own, so deleting the chat has to take it down too.
    const btwScopeKey = scopeKeyFor(`btw:${agent.key}`, workdir, sessionId);
    await purgeSession(btwScopeKey, {
      agentKey: `btw:${agent.key}`,
      workdir,
    });
    clearHistory(btwScopeKey);
    return res.json({
      ok: true,
      agent: agentPayload(agent),
      workdir,
      deletedSessionId: sessionId,
      ...result,
    });
  });

  return router;
};
