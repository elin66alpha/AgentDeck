'use strict';

const {
  AgentAuthError,
  AgentCancelledError,
} = require('./agents');

function agentPayload(agent) {
  return { key: agent.key, label: agent.label };
}

function sessionPayload(session) {
  return session ? { id: session.id, name: session.name } : null;
}

function wantsChatStream(req) {
  return String(req.get('accept') || '')
    .toLowerCase()
    .includes('text/event-stream');
}

function writeStreamEvent(res, type, payload) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
  } catch (_err) {
    // The client may have closed the app/web tab while the CLI keeps running.
  }
}

function endStream(res) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.end();
  } catch (_err) {
    // The request can already be gone; the server-side run still finishes.
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function streamTextFallback(res, requestId, agent, session, deviceId, text) {
  const value = String(text || '');
  if (!value) return;
  const chunks = value.match(/[\s\S]{1,64}/g) || [];
  for (const chunk of chunks) {
    writeStreamEvent(res, 'agent_delta', {
      requestId,
      deviceId,
      agent: agentPayload(agent),
      session: sessionPayload(session),
      text: chunk,
      createdAt: new Date().toISOString(),
    });
    await sleep(18);
  }
}

function createNoopResponder() {
  return {
    streaming: false,
    ready() {},
    event() {
      return false;
    },
    async fallbackText() {},
    final() {},
    cancelled() {},
    authError() {},
    error() {},
  };
}

function createChatResponder({ req, res }) {
  const streaming = wantsChatStream(req);
  return {
    streaming,
    ready(requestId) {
      if (!streaming) return;
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
      });
      writeStreamEvent(res, 'ready', { ok: true, requestId });
    },
    event(type, payload) {
      if (!streaming) return false;
      writeStreamEvent(res, type, payload);
      return true;
    },
    async fallbackText({ requestId, agent, session, deviceId, text }) {
      if (!streaming) return;
      await streamTextFallback(res, requestId, agent, session, deviceId, text);
    },
    final(reply) {
      if (streaming) {
        writeStreamEvent(res, 'agent_done', reply);
        endStream(res);
        return undefined;
      }
      return res.json(reply);
    },
    cancelled(payload) {
      if (streaming) {
        writeStreamEvent(res, 'agent_cancelled', payload);
        endStream(res);
        return undefined;
      }
      return res.status(499).json({
        error: 'request cancelled',
        code: 'AGENT_CANCELLED',
      });
    },
    authError(payload, body) {
      if (streaming) {
        writeStreamEvent(res, 'agent_error', payload);
        endStream(res);
        return undefined;
      }
      return res.status(424).json(body);
    },
    error(payload, body) {
      if (streaming) {
        writeStreamEvent(res, 'agent_error', payload);
        endStream(res);
        return undefined;
      }
      return res.status(500).json(body);
    },
  };
}

function directEventPayload({ requestId, agent, session, deviceId, ...payload }) {
  return {
    requestId,
    deviceId,
    agent: agentPayload(agent),
    session: sessionPayload(session),
    ...payload,
    createdAt: new Date().toISOString(),
  };
}

function defaultDependencies(dependencies) {
  const missing = [
    'broadcastScope',
    'enqueueScope',
    'getSettings',
    'runAgent',
    'runningScopes',
    'scopeChains',
    'touchChatSession',
    'updateHistoryMessage',
    'upsertHistoryMessage',
  ].filter((key) => !dependencies || !dependencies[key]);
  if (missing.length > 0) {
    throw new Error(`runAgentTurn missing dependencies: ${missing.join(', ')}`);
  }
  return dependencies;
}

function defaultFinalizeContent({ content }) {
  return content;
}

async function runAgentTurn(options) {
  const {
    agent,
    contextKey,
    dependencies,
    deviceId,
    finalizeBeforeDone = false,
    finalizeContent = defaultFinalizeContent,
    historyMetadata = {},
    initialProgressLines = [],
    notifyTaskCompletion,
    onAfterDone,
    onAfterError,
    onBeforeDone,
    onBeforeError,
    prompt,
    recordHistory = true,
    // When false, the caller records the user/human message itself (group chat
    // records one human message per round, not one per summoned agent). The
    // streaming assistant bubble is still recorded under recordHistory.
    recordUserMessage = true,
    requestId,
    responder = createNoopResponder(),
    runState = {},
    scopeKey,
    // The key turns are serialized on (enqueueScope + runningScopes). Defaults to
    // scopeKey so single-agent chat is unchanged. Group chat passes each member's
    // own session key instead, so members summoned in one message run in parallel
    // while history still lives under the shared group scopeKey.
    concurrencyKey = scopeKey,
    session,
    signal,
    workdir,
  } = options;
  const {
    broadcastScope,
    enqueueScope,
    getSettings,
    runAgent,
    runningScopes,
    scopeChains,
    touchChatSession,
    updateHistoryMessage,
    upsertHistoryMessage,
  } = defaultDependencies(dependencies);

  const agentKey = options.agentKey || agent.key;
  const createdAt = new Date().toISOString();
  const historyUserId = `${requestId}:user`;
  const historyAssistantId = `${requestId}:assistant`;
  const baseHistoryMetadata = {
    requestId,
    agentKey: agent.key,
    agentLabel: agent.label,
    sessionId: session.id,
    sessionName: session.name,
    ...historyMetadata,
  };

  if (recordHistory) {
    if (recordUserMessage) {
      upsertHistoryMessage(scopeKey, {
        id: historyUserId,
        role: 'user',
        content: prompt,
        agent: agent.key,
        createdAt,
        metadata: baseHistoryMetadata,
      });
    }
    upsertHistoryMessage(scopeKey, {
      id: historyAssistantId,
      role: 'assistant',
      content: '',
      agent: agent.key,
      createdAt,
      metadata: {
        ...baseHistoryMetadata,
        streaming: true,
        awaitingFirstToken: true,
        progressLines: initialProgressLines.filter(
          (line) => typeof line === 'string',
        ),
      },
    });
  }

  // Ordered list of assistant messages within this turn. Each entry is one
  // "segment" ({ ts, text }): the agent's mid-task follow-up notes and its final
  // answer become distinct, individually timestamped messages instead of being
  // collapsed into a single result string. Persisted in metadata.segments.
  const segments = [];
  const serializeSegments = () =>
    segments.map((segment) => ({ ts: segment.ts, text: segment.text }));

  const updateAssistantHistory = (updater) => {
    if (!recordHistory) return;
    updateHistoryMessage(scopeKey, historyAssistantId, (message) => {
      const currentMetadata =
        message &&
        typeof message.metadata === 'object' &&
        !Array.isArray(message.metadata)
          ? message.metadata
          : {};
      return updater({
        ...message,
        content: typeof message.content === 'string' ? message.content : '',
        metadata: currentMetadata,
      });
    });
  };

  const persistProgressLine = (line) => {
    updateAssistantHistory((message) => {
      const lines = Array.isArray(message.metadata.progressLines)
        ? message.metadata.progressLines.filter(
            (item) => typeof item === 'string',
          )
        : [];
      if (lines.length === 0 || lines[lines.length - 1] !== line) {
        lines.push(line);
      }
      while (lines.length > 6) lines.shift();
      return {
        ...message,
        updatedAt: new Date().toISOString(),
        metadata: {
          ...message.metadata,
          ...baseHistoryMetadata,
          streaming: true,
          progressLines: lines,
        },
      };
    });
  };

  const persistDelta = (text) => {
    if (segments.length === 0) {
      segments.push({ ts: new Date().toISOString(), text: '' });
    }
    segments[segments.length - 1].text += text;
    updateAssistantHistory((message) => ({
      ...message,
      content: `${message.content}${text}`,
      updatedAt: new Date().toISOString(),
      metadata: {
        ...message.metadata,
        ...baseHistoryMetadata,
        streaming: true,
        awaitingFirstToken: false,
        segments: serializeSegments(),
      },
    }));
  };

  // A new assistant message started inside the same turn. Open a fresh segment
  // (its own arrival timestamp) and separate it from the previous one in the
  // flat content so search/export still reads naturally.
  const persistSegmentBoundary = () => {
    segments.push({ ts: new Date().toISOString(), text: '' });
    updateAssistantHistory((message) => {
      const separator = message.content ? '\n\n' : '';
      return {
        ...message,
        content: `${message.content}${separator}`,
        updatedAt: new Date().toISOString(),
        metadata: {
          ...message.metadata,
          ...baseHistoryMetadata,
          streaming: true,
          segments: serializeSegments(),
        },
      };
    });
  };

  const finalizeAssistantHistory = (content, metadata = {}) => {
    updateAssistantHistory((message) => ({
      ...message,
      content,
      updatedAt: new Date().toISOString(),
      metadata: {
        ...message.metadata,
        ...baseHistoryMetadata,
        ...(segments.length ? { segments: serializeSegments() } : {}),
        ...metadata,
        streaming: false,
        awaitingFirstToken: false,
        // Keep the turn's progress/step lines instead of wiping them so the app
        // can fold them into a collapsed "thinking" area on the finished bubble
        // (otherwise codex's execution summary vanishes the moment it ends).
        progressLines: Array.isArray(message.metadata.progressLines)
          ? message.metadata.progressLines
          : [],
      },
    }));
  };

  responder.ready(requestId);

  let streamedText = '';
  const emitRunEvent = (event) => {
    if (!event || event.type === 'progress') {
      const line = event && event.line ? String(event.line) : '';
      if (!line) return;
      persistProgressLine(line);
      const handled = responder.event('agent_progress', directEventPayload({
        requestId,
        deviceId,
        agent,
        session,
        line,
      }));
      if (!handled) {
        broadcastScope('agent_progress', {
          scopeWorkdir: workdir,
          agent,
          session,
          requestId,
          deviceId,
          line,
        });
      }
      return;
    }
    if (event.type === 'segment') {
      persistSegmentBoundary();
      const handled = responder.event('agent_segment', directEventPayload({
        requestId,
        deviceId,
        agent,
        session,
      }));
      if (!handled) {
        broadcastScope('agent_segment', {
          scopeWorkdir: workdir,
          agent,
          session,
          requestId,
          deviceId,
        });
      }
      return;
    }
    if (event.type === 'delta') {
      const text = String(event.text || '');
      if (!text) return;
      streamedText += text;
      persistDelta(text);
      const handled = responder.event('agent_delta', directEventPayload({
        requestId,
        deviceId,
        agent,
        session,
        text,
      }));
      if (!handled) {
        broadcastScope('agent_delta', {
          scopeWorkdir: workdir,
          agent,
          session,
          requestId,
          deviceId,
          text,
        });
      }
    }
  };

  broadcastScope('agent_start', {
    scopeWorkdir: workdir,
    agent,
    session,
    requestId,
    deviceId,
  });
  const willQueue =
    runningScopes.has(concurrencyKey) || scopeChains.has(concurrencyKey);
  if (willQueue) {
    broadcastScope('agent_queued', {
      scopeWorkdir: workdir,
      agent,
      session,
      requestId,
      deviceId,
    });
    responder.event('agent_queued', directEventPayload({
      requestId,
      deviceId,
      agent,
      session,
    }));
  }

  try {
    const content = await enqueueScope(concurrencyKey, async () => {
      // The turn may have been cancelled while waiting its turn in the queue.
      if (runState.cancelled) throw new AgentCancelledError();
      runningScopes.add(concurrencyKey);
      try {
        return await runAgent(agentKey, prompt, emitRunEvent, {
          sessionKey: scopeKey,
          ...(signal ? { signal } : {}),
          workdir,
          settings: getSettings(agentKey, contextKey),
        });
      } finally {
        runningScopes.delete(concurrencyKey);
      }
    });
    if (responder.streaming && !streamedText.trim()) {
      await responder.fallbackText({
        requestId,
        agent,
        session,
        deviceId,
        text: content,
      });
    }
    // A multi-message turn (mid-task follow-ups + a final answer) is fully
    // captured only by the joined segment text, so it supersedes a runner's
    // single result string. For a single-message turn the runner's content is
    // authoritative (it can be fuller than what streamed, e.g. codex's -o file),
    // so we keep it and reconcile the lone segment to match.
    const multiSegment = segments.length > 1;
    const baseContent = multiSegment
      ? segments
          .map((segment) => segment.text)
          .join('\n\n')
          .trim()
      : content;
    const finalContent = finalizeContent({
      content: baseContent,
      rawContent: content,
      streamedText,
      segments,
    });
    if (!multiSegment) {
      // Collapse to a single segment whose text is exactly the final content, so
      // the app renders one timestamped message that matches finalContent.
      const ts = segments.length ? segments[0].ts : new Date().toISOString();
      segments.length = 0;
      if (finalContent) segments.push({ ts, text: finalContent });
    }
    touchChatSession(contextKey, session.id);
    if (finalizeBeforeDone) {
      finalizeAssistantHistory(finalContent);
    }
    if (typeof onBeforeDone === 'function') {
      onBeforeDone({ content: finalContent, rawContent: content, streamedText });
    }
    broadcastScope('agent_done', {
      scopeWorkdir: workdir,
      agent,
      session,
      requestId,
      deviceId,
    });
    if (typeof notifyTaskCompletion === 'function') {
      notifyTaskCompletion({
        agent,
        scopeWorkdir: workdir,
        content: content || streamedText,
      });
    }
    if (!finalizeBeforeDone) {
      finalizeAssistantHistory(finalContent);
    }
    const completedAt = new Date().toISOString();
    const reply = {
      requestId,
      agent: agentPayload(agent),
      session: sessionPayload(session),
      message: {
        role: 'assistant',
        content: finalContent,
        segments: serializeSegments(),
        createdAt: completedAt,
      },
    };
    responder.final(reply);
    if (typeof onAfterDone === 'function') {
      onAfterDone({ content: finalContent, rawContent: content, streamedText, reply });
    }
    return { status: 'done', content: finalContent, rawContent: content, streamedText, reply };
  } catch (err) {
    if (err instanceof AgentCancelledError || err.code === 'AGENT_CANCELLED') {
      finalizeAssistantHistory(streamedText, { cancelled: true });
      if (!runState.cancelEventSent) {
        runState.cancelEventSent = true;
        broadcastScope('agent_cancelled', {
          scopeWorkdir: workdir,
          agent,
          session,
          requestId,
          deviceId,
        });
      }
      responder.cancelled(directEventPayload({
        requestId,
        deviceId,
        agent,
        session,
      }));
      return { status: 'cancelled', streamedText };
    }

    if (err instanceof AgentAuthError || err.code === 'NOT_LOGGED_IN') {
      const message =
        `${agentPayload(agent).label} is not logged in on the backend host. ` +
        'Log in there, then try again.';
      finalizeAssistantHistory(message, { errorCode: 'NOT_LOGGED_IN' });
      if (typeof onBeforeError === 'function') {
        onBeforeError({ err, errorMessage: message, code: 'NOT_LOGGED_IN' });
      }
      broadcastScope('agent_error', {
        scopeWorkdir: workdir,
        agent,
        session,
        requestId,
        deviceId,
        error: message,
        code: 'NOT_LOGGED_IN',
      });
      responder.authError(directEventPayload({
        requestId,
        deviceId,
        agent,
        session,
        error: message,
        code: 'NOT_LOGGED_IN',
      }), {
        error: message,
        code: 'NOT_LOGGED_IN',
        agent: agent.key,
      });
      if (typeof onAfterError === 'function') {
        onAfterError({ err, errorMessage: message, code: 'NOT_LOGGED_IN' });
      }
      return { status: 'error', err, errorMessage: message, code: 'NOT_LOGGED_IN' };
    }

    const errorMessage = err.message || 'agent request failed';
    const errorCode = err.code || options.defaultErrorCode || 'AGENT_ERROR';
    finalizeAssistantHistory(errorMessage, { errorCode });
    if (typeof onBeforeError === 'function') {
      onBeforeError({ err, errorMessage, code: err.code });
    }
    broadcastScope('agent_error', {
      scopeWorkdir: workdir,
      agent,
      session,
      requestId,
      deviceId,
      error: errorMessage,
      code: err.code,
    });
    responder.error(directEventPayload({
      requestId,
      deviceId,
      agent,
      session,
      error: errorMessage,
      code: err.code,
    }), { error: errorMessage });
    if (typeof onAfterError === 'function') {
      onAfterError({ err, errorMessage, code: err.code });
    }
    return { status: 'error', err, errorMessage, code: err.code };
  }
}

module.exports = {
  agentPayload,
  createChatResponder,
  createNoopResponder,
  runAgentTurn,
  sessionPayload,
};
