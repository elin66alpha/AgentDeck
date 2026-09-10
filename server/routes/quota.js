'use strict';

const express = require('express');

module.exports = function createQuotaRouter(ctx) {
  const {
    agentRequiredOrUnknownError,
    buildUsageReport,
    cancelQuotaSchedule,
    createQuotaSchedule,
    eventWorkdir,
    listQuotaSchedules,
    resolveAgentScope,
    sendEvent,
  } = ctx;
  const router = express.Router();

  router.get('/api/usage', async (req, res) => {
    try {
      const report = await buildUsageReport({ source: req.query.source });
      return res.json(report);
    } catch (err) {
      return res.status(err.status || 500).json({ error: err.message });
    }
  });

  router.get('/api/quota-schedules', (req, res) => {
    const workdir = eventWorkdir(req);
    return res.json({ workdir, schedules: listQuotaSchedules({ workdir }) });
  });

  router.post('/api/quota-schedules', (req, res) => {
    const sourceKey = String(req.body.sourceKey || '').trim();
    const agentKey = String(req.body.agent || req.body.agentKey || '').trim();
    const requestedSessionId = String(req.body.sessionId || '').trim();
    if (!['claude', 'codex'].includes(sourceKey)) {
      return res.status(400).json({
        error: 'sourceKey must be claude or codex',
        code: 'INVALID_QUOTA_SOURCE',
      });
    }
    const scope = resolveAgentScope(req, res, {
      agentKey,
      sessionId: requestedSessionId,
      agentError: agentRequiredOrUnknownError,
    });
    if (!scope) return;
    const { agent, workdir, session: chatSession } = scope;
    try {
      const schedule = createQuotaSchedule({
        sourceKey,
        agentKey: agent.key,
        sessionId: chatSession.id,
        sessionName: chatSession.name,
        workdir,
        prompt: req.body.prompt,
        targetResetsAt: req.body.targetResetsAt,
        replaceExisting: req.body.replaceExisting === true,
      });
      sendEvent('quota_schedule_changed', {
        scopeWorkdir: workdir,
        action: req.body.replaceExisting === true ? 'replace' : 'create',
        schedule,
        createdAt: new Date().toISOString(),
      });
      return res.json({ ok: true, schedule });
    } catch (err) {
      return res.status(err.code === 'SCHEDULE_EXISTS' ? 409 : 400).json({
        error: err.message,
        code: err.code || 'SCHEDULE_CREATE_FAILED',
      });
    }
  });

  router.post('/api/quota-schedules/cancel', (req, res) => {
    const id = String(req.body.id || '').trim();
    if (!id) {
      return res.status(400).json({ error: 'id is required' });
    }
    try {
      const schedule = cancelQuotaSchedule(id);
      if (!schedule) {
        return res.status(404).json({
          error: 'scheduled message not found',
          code: 'SCHEDULE_NOT_FOUND',
        });
      }
      sendEvent('quota_schedule_changed', {
        scopeWorkdir: schedule.workdir,
        action: 'cancel',
        schedule,
        createdAt: new Date().toISOString(),
      });
      return res.json({ ok: true, schedule });
    } catch (err) {
      return res.status(409).json({
        error: err.message,
        code: err.code || 'SCHEDULE_CANCEL_FAILED',
      });
    }
  });

  return router;
};
