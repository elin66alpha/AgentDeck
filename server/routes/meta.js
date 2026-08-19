'use strict';

const { execFile } = require('child_process');
const express = require('express');

const { clearModelDiscoveryCache } = require('../lib/model-discovery');
const {
  getAgentStatuses: defaultGetAgentStatuses,
} = require('../lib/agent-status');

module.exports = function createMetaRouter(ctx) {
  const {
    CLI,
    DEFAULT_AGENT,
    ENABLE_QUOTA_WATCH,
    HOST,
    MAX_DOWNLOAD_BYTES,
    MAX_UPLOAD_BYTES,
    PORT,
    PUBLIC_BASE_URL,
    TIMEOUT_MS,
    WEB_BUILD_DIR,
    activeRequests,
    agentRequiredError,
    authStatus,
    bearerToken,
    buildDiagnostics,
    describeAgent,
    deleteRevokedTokenById,
    eventClients,
    eventWorkdir,
    formatUptime,
    getAgent,
    getAgentStatuses = defaultGetAgentStatuses,
    getDefaultWorkdir,
    getSettings,
    listAgents,
    listTokenSummaries,
    normalizeDeviceId,
    os,
    revokeTokenById,
    resolveAgentScope,
    runningScopes,
    scopeChains,
    setSettings,
    terminalManager,
    workdirPresence,
  } = ctx;
  const router = express.Router();

  router.get('/api/health', (_req, res) => {
    res.json({ ok: true, time: new Date().toISOString() });
  });

  router.get('/api/agents', (_req, res) => {
    const statuses = getAgentStatuses();
    res.json({
      defaultAgent: DEFAULT_AGENT,
      agents: listAgents().map((agent) => {
        const status = statuses[agent.key] || {};
        const installed = status.installed === true;
        const authed = status.authed === true;
        return {
          ...agent,
          installed,
          authed,
          authKind: status.authKind || 'unknown',
          // Epoch ms at which the stored OAuth credential runs out, so the app
          // can say how many days are left before a login on the host is due.
          // null for agents whose credential carries no expiry.
          credentialExpiresAt: Number.isFinite(status.credentialExpiresAt)
            ? status.credentialExpiresAt
            : null,
          // claude/codex (oauth) gate on login; hermes/opencode are managed
          // out-of-band (the user sets up their key on the host), so they are
          // usable whenever installed and never gate on a key Relay can't see.
          usable:
            installed &&
            (authed || agent.key === 'opencode' || agent.key === 'hermes'),
        };
      }),
    });
  });

  // Run a CLI binary with fixed argv (no user-controlled tokens) and resolve with
  // its trimmed output. Used for `<cli> --version` and `<cli> update`.
  function runCliCommand(bin, args, timeoutMs) {
    return new Promise((resolve) => {
      execFile(
        bin,
        args,
        { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
        (err, stdout, stderr) => {
          const out = String(stdout || '').trim();
          const errOut = String(stderr || '').trim();
          resolve({
            ok: !err,
            code: err && typeof err.code === 'number' ? err.code : err ? 1 : 0,
            stdout: out,
            stderr: errOut,
            text: out || errOut,
            timedOut: !!(err && err.killed),
          });
        },
      );
    });
  }

  // The model and effort pages show the installed CLI version, so this ran a
  // subprocess every time one of them opened. The version only moves when the
  // binary is replaced, so remember it and re-run at most once a minute; the
  // updater below overwrites the entry with the version it just installed.
  const VERSION_TTL_MS = 60_000;
  const versionCache = new Map();

  async function cliVersion(agentKey) {
    const cli = CLI[agentKey];
    if (!cli) return '';
    const cached = versionCache.get(agentKey);
    if (cached && Date.now() - cached.at < VERSION_TTL_MS) return cached.version;
    const result = await runCliCommand(cli.bin, cli.versionArgs, 15000);
    // Versions print as e.g. "2.1.161 (Claude Code)" / "codex-cli 0.132.0".
    const version = result.ok ? result.text.split('\n')[0].trim() : '';
    versionCache.set(agentKey, { version, at: Date.now() });
    return version;
  }

  // Catalog of selectable model/effort/permission/fast options for one agent. Model
  // and effort choices can be discovered from the installed CLI, so no workdir
  // is needed but the result may change after a CLI update.
  router.get('/api/agent-options', (req, res) => {
    const agent = getAgent(String(req.query.agent || '').trim());
    if (!agent) {
      return res.status(400).json({ error: 'agent is required' });
    }
    return res.json({ ok: true, ...describeAgent(agent.key) });
  });

  // Current model/effort/permission/fast selection for the request's workdir+agent
  // scope (shared by every device in that scope).
  router.get('/api/agent-settings', (req, res) => {
    const scope = resolveAgentScope(req, res, {
      agentFrom: 'query',
      requireSession: false,
      agentError: agentRequiredError,
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    return res.json({
      ok: true,
      agent: agent.key,
      workdir,
      settings: getSettings(agent.key, contextKey),
    });
  });

  // Update the selection for a scope. Body includes any supported string group.
  // Only provided groups change; invalid ids fall back to the agent default.
  router.post('/api/agent-settings', (req, res) => {
    const body = req.body || {};
    const scope = resolveAgentScope(req, res, {
      agentKey: body.agent,
      requireSession: false,
      agentError: agentRequiredError,
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const partial = {};
    for (const group of ['model', 'effort', 'permission', 'fast']) {
      if (typeof body[group] === 'string') partial[group] = body[group];
    }
    const settings = setSettings(agent.key, contextKey, partial);
    return res.json({ ok: true, agent: agent.key, workdir, settings });
  });

  // Installed CLI version for the agent (for the model page's version label).
  router.get('/api/agent-version', async (req, res) => {
    const agent = getAgent(String(req.query.agent || '').trim());
    if (!agent) {
      return res.status(400).json({ error: 'agent is required' });
    }
    const version = await cliVersion(agent.key);
    return res.json({ ok: true, agent: agent.key, version });
  });

  // Update the agent's CLI binary so newly shipped models become selectable.
  // Runs `<cli> update` (fixed argv); returns the before/after version. Protected
  // by the same bearer-token middleware as every other /api/* route.
  router.post('/api/agent-update', async (req, res) => {
    const agent = getAgent(String((req.body || {}).agent || '').trim());
    if (!agent) {
      return res.status(400).json({ error: 'agent is required' });
    }
    const cli = CLI[agent.key];
    if (!cli) {
      return res.status(400).json({ error: `no updater for ${agent.key}` });
    }
    const before = await cliVersion(agent.key);
    const result = await runCliCommand(cli.bin, cli.updateArgs, 180000);
    clearModelDiscoveryCache(agent.key);
    versionCache.delete(agent.key);
    const after = await cliVersion(agent.key);
    return res.json({
      ok: result.ok,
      agent: agent.key,
      before,
      after,
      changed: !!after && after !== before,
      timedOut: result.timedOut,
      output: result.text.slice(0, 4000),
    });
  });

  // Best-effort login state per agent so the app can warn before sending a
  // message. loggedIn is true/false when detectable from on-disk credentials,
  // or null when it cannot be determined without running the CLI.
  router.get('/api/auth/status', (_req, res) => {
    res.json({
      agents: listAgents().map((agent) => ({
        key: agent.key,
        label: agent.label,
        loggedIn: authStatus(agent.key),
      })),
    });
  });

  router.get('/api/tokens', (req, res) => {
    res.json({
      tokens: listTokenSummaries({ currentToken: bearerToken(req) }),
    });
  });

  router.post('/api/tokens/:id/revoke', (req, res) => {
    const id = String(req.params.id || '').trim();
    const revoked = revokeTokenById(id);
    if (!revoked) {
      return res.status(404).json({ error: 'token not found' });
    }
    terminalManager?.closeSession(revoked.id);
    res.json({
      token: {
        id: revoked.id || '',
        label: revoked.label || '',
        createdAt: revoked.createdAt || '',
        revoked: true,
        revokedAt: revoked.revokedAt || '',
        current: String(revoked.token || '') === bearerToken(req),
      },
    });
  });

  router.post('/api/tokens/:id/delete', (req, res) => {
    const id = String(req.params.id || '').trim();
    const deleted = deleteRevokedTokenById(id);
    if (deleted === null) {
      return res.status(404).json({ error: 'token not found' });
    }
    if (deleted === false) {
      return res.status(409).json({
        error: 'token must be revoked before deletion',
        code: 'TOKEN_NOT_REVOKED',
      });
    }
    res.json({ ok: true, id: deleted.id || id });
  });

  router.get('/api/status', (req, res) => {
    res.json({
      ok: true,
      defaultAgent: DEFAULT_AGENT,
      workdir: eventWorkdir(req),
      defaultWorkdir: getDefaultWorkdir(),
      systemUptime: formatUptime(os.uptime()),
      processUptime: formatUptime(process.uptime()),
      agentTimeoutMs: TIMEOUT_MS,
      quotaWatch: ENABLE_QUOTA_WATCH,
      publicBaseUrl: PUBLIC_BASE_URL,
    });
  });

  router.get('/api/diagnostics', (req, res) => {
    const workdir = eventWorkdir(req);
    res.json(
      buildDiagnostics({
        workdir,
        defaultWorkdir: getDefaultWorkdir(),
        publicBaseUrl: PUBLIC_BASE_URL,
        host: HOST,
        port: PORT,
        quotaWatch: ENABLE_QUOTA_WATCH,
        agentTimeoutMs: TIMEOUT_MS,
        maxUploadBytes: MAX_UPLOAD_BYTES,
        maxDownloadBytes: MAX_DOWNLOAD_BYTES,
        webBuildDir: WEB_BUILD_DIR,
        agents: listAgents(),
        runtime: {
          sseClients: eventClients.size,
          activeRequests: activeRequests.size,
          runningScopes: runningScopes.size,
          queuedScopes: scopeChains.size,
        },
      }),
    );
  });

  router.get('/api/events', (req, res) => {
    const deviceId = normalizeDeviceId(req.get('x-device-id'));
    // Scope this subscription to the device's current work directory so it only
    // receives chat events for the conversation it is viewing. The client
    // reconnects with a new x-workdir header when the user switches paths.
    const workdir = eventWorkdir(req);
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    const client = { res, deviceId, workdir };
    eventClients.add(client);
    workdirPresence.set(workdir, (workdirPresence.get(workdir) || 0) + 1);
    res.write(`event: ready\ndata: ${JSON.stringify({ ok: true })}\n\n`);

    const heartbeat = setInterval(() => {
      res.write(`event: heartbeat\ndata: ${JSON.stringify({ at: new Date().toISOString() })}\n\n`);
    }, 30_000);

    req.on('close', () => {
      clearInterval(heartbeat);
      eventClients.delete(client);
      const remaining = (workdirPresence.get(workdir) || 1) - 1;
      if (remaining > 0) workdirPresence.set(workdir, remaining);
      else workdirPresence.delete(workdir);
    });
  });

  return router;
};
