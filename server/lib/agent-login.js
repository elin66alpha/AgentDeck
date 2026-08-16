'use strict';

const { spawn } = require('child_process');
const { randomUUID } = require('crypto');

const { commandExists } = require('./agents');

const SESSION_TTL_MS = 15 * 60 * 1000;
const SESSION_MAX_RUNNING_MS = 15 * 60 * 1000;
const URL_RE = /https?:\/\/[^\s"'<>]+/g;
const URL_TRAILING_PUNCT_RE = /[),.;]+$/;

const AUTH_HOSTS = {
  claude: ['anthropic.com', 'claude.ai'],
  codex: ['openai.com', 'chatgpt.com'],
};
const AUTH_URL_RE = /(auth|authorize|device|login|oauth|verify)/i;

const LOGIN_COMMANDS = {
  claude: ['claude', 'auth', 'login', '--claudeai'],
  codex: ['codex', 'login', '--device-auth'],
};

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function scriptCommand(args) {
  return args.map(shellQuote).join(' ');
}

function redactLoginText(text) {
  return String(text || '').replace(URL_RE, '[login URL]');
}

function normalizeUrl(value) {
  return String(value || '').replace(URL_TRAILING_PUNCT_RE, '');
}

function hostMatches(hostname, expectedHost) {
  return hostname === expectedHost || hostname.endsWith(`.${expectedHost}`);
}

function loginUrlScore(agent, value) {
  const normalized = normalizeUrl(value);
  if (!normalized) return Number.NEGATIVE_INFINITY;
  try {
    const parsed = new URL(normalized);
    const hostname = parsed.hostname.toLowerCase();
    let score = parsed.protocol === 'https:' ? 10 : 0;
    if ((AUTH_HOSTS[agent] || []).some((host) => hostMatches(hostname, host))) {
      score += 1000;
    }
    const authText = `${hostname}${parsed.pathname}${parsed.search}`;
    if (AUTH_URL_RE.test(authText)) score += 200;
    score += Math.min(authText.length, 300);
    return score;
  } catch (_err) {
    return normalized.length;
  }
}

function selectLoginUrl(agent, urls) {
  let best = '';
  let bestScore = Number.NEGATIVE_INFINITY;
  for (const rawUrl of urls) {
    const url = normalizeUrl(rawUrl);
    const score = loginUrlScore(agent, url);
    if (score > bestScore) {
      best = url;
      bestScore = score;
    }
  }
  return { url: best, score: bestScore };
}

function createAgentLoginManager(options = {}) {
  const sessions = new Map();
  const spawnFn = options.spawn || spawn;
  const nowFn = options.now || (() => Date.now());
  const idFn = options.randomUUID || randomUUID;
  const commandExistsFn = options.commandExists || commandExists;
  const sessionTtlMs = options.sessionTtlMs || SESSION_TTL_MS;
  const maxRunningMs = options.maxRunningMs || SESSION_MAX_RUNNING_MS;

  function sessionPayload(session) {
    return {
      sessionId: session.id,
      agent: session.agent,
    };
  }

  function emit(session, type, payload = {}) {
    const event = {
      type,
      data: {
        ...sessionPayload(session),
        ...payload,
      },
    };
    for (const listener of session.listeners) {
      try {
        listener(event);
      } catch (_err) {
        // A dropped SSE client should not affect the login process.
      }
    }
  }

  function replay(session, listener) {
    listener({
      type: 'login_started',
      data: sessionPayload(session),
    });
    if (session.url) {
      listener({
        type: 'login_url',
        data: { ...sessionPayload(session), url: session.url },
      });
    }
    if (session.status === 'done') {
      listener({
        type: 'login_done',
        data: sessionPayload(session),
      });
    } else if (session.status === 'error') {
      listener({
        type: 'login_error',
        data: {
          ...sessionPayload(session),
          error: session.error || 'Login failed.',
        },
      });
    }
  }

  function handleOutput(session, chunk) {
    const text = String(chunk || '');
    session.output += text;
    const urls = text.match(URL_RE) || [];
    const selectedUrl = selectLoginUrl(session.agent, urls);
    if (
      selectedUrl.url
      && selectedUrl.url !== session.url
      && selectedUrl.score >= session.urlScore
    ) {
      session.url = selectedUrl.url;
      session.urlScore = selectedUrl.score;
      emit(session, 'login_url', { url: session.url });
    }
    if (!session.codeSubmitted && text.trim()) {
      emit(session, 'login_output', { text: redactLoginText(text).slice(-2000) });
    }
  }

  function finish(session, status, error = '') {
    if (session.status !== 'running') return;
    session.status = status;
    session.error = error;
    session.finishedAt = nowFn();
    emit(session, status === 'done' ? 'login_done' : 'login_error', {
      ...(error ? { error } : {}),
    });
  }

  function killChild(session) {
    if (!session.child || typeof session.child.kill !== 'function') return;
    try {
      session.child.kill('SIGTERM');
    } catch (_err) {
      // The child may already have exited; finish() still records the terminal state.
    }
  }

  function abortSession(session, message) {
    if (session.status !== 'running') return;
    killChild(session);
    finish(session, 'error', message);
  }

  function cleanup() {
    const now = nowFn();
    for (const [id, session] of sessions.entries()) {
      if (
        session.status === 'running'
        && now - session.createdAt > maxRunningMs
      ) {
        abortSession(session, 'Login session timed out.');
      }
      if (
        session.status !== 'running'
        && now - (session.finishedAt || session.createdAt) > sessionTtlMs
      ) {
        sessions.delete(id);
      }
    }
  }

  function start(agent) {
    cleanup();
    const args = LOGIN_COMMANDS[agent];
    if (!args) {
      const err = new Error(`Login is not supported for ${agent}`);
      err.code = 'LOGIN_UNSUPPORTED';
      throw err;
    }
    if (!commandExistsFn(args[0])) {
      const err = new Error(`${agent} CLI is not installed`);
      err.code = 'CLI_NOT_INSTALLED';
      throw err;
    }
    const id = idFn();
    const session = {
      id,
      agent,
      status: 'running',
      url: '',
      urlScore: Number.NEGATIVE_INFINITY,
      output: '',
      error: '',
      codeSubmitted: false,
      createdAt: nowFn(),
      finishedAt: null,
      listeners: new Set(),
      child: null,
    };
    sessions.set(id, session);

    const child = spawnFn(
      'script',
      ['-qfec', scriptCommand(args), '/dev/null'],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    session.child = child;
    child.stdout?.on('data', (chunk) => handleOutput(session, chunk));
    child.stderr?.on('data', (chunk) => handleOutput(session, chunk));
    child.on('error', (err) => {
      finish(session, 'error', err.message || 'Failed to start login.');
    });
    child.on('exit', (code, signal) => {
      if (code === 0) {
        finish(session, 'done');
      } else {
        finish(
          session,
          'error',
          signal
            ? `Login process ended with signal ${signal}.`
            : `Login process exited with code ${code}.`,
        );
      }
    });
    emit(session, 'login_started');
    return session;
  }

  function subscribe(sessionId, listener) {
    cleanup();
    const session = sessions.get(sessionId);
    if (!session) return () => {};
    session.listeners.add(listener);
    replay(session, listener);
    // Only drop the listener on disconnect — do NOT kill the login. The CLI
    // completes the OAuth flow on its own in the PTY, and the user typically has
    // to leave the app (backgrounding it, which drops this SSE) to authorize in a
    // browser. Killing here would abort a login at the worst moment. Abandoned
    // sessions are still reaped by the maxRunningMs timeout in cleanup().
    return () => {
      session.listeners.delete(listener);
    };
  }

  function submitCode(sessionId, code) {
    const session = sessions.get(sessionId);
    if (!session) {
      const err = new Error('Login session not found.');
      err.code = 'LOGIN_SESSION_NOT_FOUND';
      throw err;
    }
    if (session.status !== 'running' || !session.child?.stdin?.writable) {
      const err = new Error('Login session is not accepting input.');
      err.code = 'LOGIN_SESSION_CLOSED';
      throw err;
    }
    session.codeSubmitted = true;
    session.child.stdin.write(`${String(code || '').trim()}\n`);
  }

  function status(sessionId) {
    cleanup();
    const session = sessions.get(sessionId);
    if (!session) return null;
    return {
      sessionId: session.id,
      agent: session.agent,
      status: session.status,
      url: session.url,
      error: session.error,
    };
  }

  return { start, subscribe, submitCode, status, cleanup };
}

module.exports = {
  LOGIN_COMMANDS,
  createAgentLoginManager,
  selectLoginUrl,
  scriptCommand,
};
