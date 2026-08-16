'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const { getDefaultWorkdir } = require('./workdir');
const {
  claudeSdkOptions,
  acpSessionOptions,
  codexSessionOptions,
} = require('./agent-options');
const { createJsonStore } = require('./json-store');
const { createClaudeSessionPool } = require('./claude-session-pool');
const { createAcpSessionPool } = require('./acp-session-pool');
const { createCodexSessionPool } = require('./codex-session-pool');

const TIMEOUT_MS = parseInt(
  process.env.AGENT_TIMEOUT_MS || String(60 * 60 * 1000),
  10,
);

// Persistent CLI sessions: each session key keeps one continuous conversation.
// Keys are scoped by workdir + agent + optional chat session id. clearSession
// lets the app start a fresh machine-side conversation after history is cleared.
const SESSION_FILE = path.join(__dirname, '..', 'agent-sessions.json');

class AgentCancelledError extends Error {
  constructor() {
    super('request cancelled');
    this.name = 'AgentCancelledError';
    this.code = 'AGENT_CANCELLED';
  }
}

// Raised when an agent CLI has no logged-in account / no usable API key, so the
// caller can surface a real "log in on the host" state instead of returning the
// raw CLI error as if it were the assistant's reply.
class AgentAuthError extends Error {
  constructor(agentKey) {
    super(`${agentKey} is not logged in`);
    this.name = 'AgentAuthError';
    this.code = 'NOT_LOGGED_IN';
    this.agent = agentKey;
  }
}

// Heuristic detection of "the CLI has no logged-in account / no API key". The
// CLIs expose no machine-readable signal for this, so we match the human
// messages they print. Kept deliberately auth-specific so it never swallows the
// separate "resumed session not found" messages, which are handled on their own.
const AUTH_ERROR_RE = new RegExp(
  [
    'not logged in',
    'not authenticated',
    'please log\\s?in',
    'please sign in',
    '(?:must|need to) log\\s?in',
    'run\\s+`?(?:claude|codex)?\\s*login`?',
    '/login\\b',
    'login (?:required|expired)',
    'unauthorized',
    'authentication (?:failed|required|error)',
    'invalid api key',
    '(?:missing|no) api key',
  ].join('|'),
  'i',
);

function isAuthError(text) {
  return AUTH_ERROR_RE.test(String(text || ''));
}

// Cached, atomic store for the resumable-session map. The cache keeps the
// per-turn getSession lookup off the disk, and the atomic write means a crash
// mid-save can't truncate the file.
const sessionStore = createJsonStore(SESSION_FILE, { defaultValue: {} });

function getSession(sessionKey) {
  return sessionStore.load()[sessionKey] || null;
}

function setSession(sessionKey, value) {
  sessionStore.mutate((sessions) => {
    sessions[sessionKey] = value;
  });
}

function clearSession(sessionKey) {
  if (!(sessionKey in sessionStore.load())) return false;
  sessionStore.mutate((sessions) => {
    delete sessions[sessionKey];
  });
  return true;
}

// Some installers (opencode) put the binary in a per-user dir that isn't on the
// server's PATH, so detection scans PATH first, then known fallback locations.
// Results are cached briefly so /api/agents stays fast.
const LOCATE_BIN_TTL_MS = 60 * 1000;
const locateBinCache = new Map();

const BIN_FALLBACKS = {
  opencode: [path.join(os.homedir(), '.opencode', 'bin', 'opencode')],
  hermes: [path.join(os.homedir(), '.local', 'bin', 'hermes')],
};

function executableInPath(bin) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts =
    process.platform === 'win32'
      ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';')
      : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const full = path.join(dir, bin + ext);
      try {
        fs.accessSync(full, fs.constants.X_OK);
        return full;
      } catch (_err) {
        // Keep scanning.
      }
    }
  }
  return null;
}

// Resolve a CLI to a runnable path: PATH first (return the bare name so spawn
// uses PATH), then per-user fallback locations (return the absolute path).
// Returns null when the binary can't be found anywhere.
function locateBin(bin) {
  const cached = locateBinCache.get(bin);
  if (cached && Date.now() - cached.at < LOCATE_BIN_TTL_MS) {
    return cached.value;
  }
  let value = executableInPath(bin) ? bin : null;
  if (!value) {
    for (const candidate of BIN_FALLBACKS[bin] || []) {
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        value = candidate;
        break;
      } catch (_err) {
        // Try the next candidate.
      }
    }
  }
  locateBinCache.set(bin, { value, at: Date.now() });
  return value;
}

function commandExists(bin) {
  return locateBin(bin) !== null;
}

function emit(onEvent, event) {
  if (typeof onEvent !== 'function' || !event) return;
  try {
    if (typeof event === 'string') {
      onEvent({ type: 'progress', line: event });
    } else {
      onEvent(event);
    }
  } catch (_err) {
    // Progress callbacks should not affect the running agent.
  }
}

function oneLine(value, max = 100) {
  const text = String(value).replace(/\s+/g, ' ').trim();
  return text.length > max ? `${text.slice(0, max - 1)}...` : text;
}

function makeDeltaEmitter(onEvent) {
  let streamed = '';
  return (value) => {
    const text = String(value || '');
    if (!text) return;

    let delta = text;
    if (streamed && text.startsWith(streamed)) {
      delta = text.slice(streamed.length);
    } else if (streamed && streamed.endsWith(text)) {
      delta = '';
    }

    if (!delta) return;
    streamed += delta;
    emit(onEvent, { type: 'delta', text: delta });
  };
}

// Shared tail for every runner: resolve the __retry marker (a stale resumed
// session was cleared — run the turn once more from scratch) and the
// __authError marker (raise a typed error instead of returning CLI text).
function finishRun(resultPromise, { agentKey, onEvent, retry }) {
  return resultPromise.then((result) => {
    if (result && result.__retry && retry) {
      emit(onEvent, 'The old session is no longer valid. Retrying with a new session...');
      return retry();
    }
    if (result && result.__authError) throw new AgentAuthError(agentKey);
    return result;
  });
}

function toolBrief(name, input) {
  const data = input || {};
  let detail = '';
  if (name === 'Bash') detail = data.command || '';
  else if (
    name === 'Read' ||
    name === 'Edit' ||
    name === 'Write' ||
    name === 'NotebookEdit'
  ) {
    detail = data.file_path || '';
  } else if (name === 'Grep' || name === 'Glob') {
    detail = data.pattern || data.glob || '';
  } else if (name === 'Task') {
    detail = data.description || '';
  } else if (name === 'WebFetch' || name === 'WebSearch') {
    detail = data.url || data.query || '';
  } else {
    detail = Object.keys(data).slice(0, 2).join(', ');
  }
  return `${name}${detail ? `: ${oneLine(detail, 80)}` : ''}`;
}

// Relay drives whichever `claude` the host has installed and logged into, so
// the SDK is pointed at that binary instead of the copy it ships — same
// version, same auth, same settings as the CLI shown in the app. Falling back
// to null lets the SDK resolve its own bundled binary.
function claudeExecutablePath() {
  return process.env.RELAY_CLAUDE_BIN || executableInPath('claude') || null;
}

// One live CLI process per scope, reused across turns instead of respawned per
// turn. See claude-session-pool.js for the lifecycle and why the pool is only
// ever a cache over the stored session id.
const claudePool = createClaudeSessionPool({ turnTimeoutMs: TIMEOUT_MS });

// opencode and hermes both ship an `acp` subcommand: the same idea as the
// Claude SDK over a different protocol — one process that stays open and takes
// turn after turn. See acp-session-pool.js. ACP itself has no delete, so the
// purge path shells out to each CLI, which owns its own session store.
const opencodePool = createAcpSessionPool({
  agentKey: 'opencode',
  turnTimeoutMs: TIMEOUT_MS,
  command: () => {
    const bin = locateBin('opencode');
    return bin ? { cmd: bin, args: ['acp'] } : null;
  },
  deleteCommand: (sessionId) => {
    const bin = locateBin('opencode');
    return bin ? { cmd: bin, args: ['session', 'delete', sessionId] } : null;
  },
});

const hermesPool = createAcpSessionPool({
  agentKey: 'hermes',
  turnTimeoutMs: TIMEOUT_MS,
  command: () => {
    const bin = locateBin('hermes');
    return bin ? { cmd: bin, args: ['acp'] } : null;
  },
  deleteCommand: (sessionId) => {
    const bin = locateBin('hermes');
    return bin
      ? { cmd: bin, args: ['sessions', 'delete', '--yes', sessionId] }
      : null;
  },
});

// codex speaks its own app-server protocol rather than ACP, but the pool
// mechanics are shared. See codex-session-pool.js.
const codexPool = createCodexSessionPool({
  agentKey: 'codex',
  turnTimeoutMs: TIMEOUT_MS,
  command: () => {
    const bin = locateBin('codex');
    return bin ? { cmd: bin, args: ['app-server'] } : null;
  },
});

// Agents whose sessions Relay hosts itself, so deleting a chat can really
// delete the machine-side conversation instead of just forgetting its id.
const SESSION_POOLS = {
  claude: claudePool,
  opencode: opencodePool,
  hermes: hermesPool,
  codex: codexPool,
};

// Delete a scope's conversation for good. Deleting a chat in the app means the
// conversation is gone, so a pooled scope also loses its CLI-side transcript:
// without that, the id would be forgotten while the transcript lingered on
// disk, resumable forever.
async function purgeSession(sessionKey, options = {}) {
  const pool = SESSION_POOLS[String(options.agentKey || '')];
  if (!pool) return clearSession(sessionKey);
  const prior = getSession(sessionKey);
  const cleared = clearSession(sessionKey);
  await pool.forget(
    sessionKey,
    prior && prior.id
      ? {
          purge: true,
          sessionId: prior.id,
          cwd: options.workdir || getDefaultWorkdir(),
        }
      : {},
  );
  return cleared;
}

// Close every live agent process. Called on shutdown so a restart never leaves
// orphaned CLI processes holding memory.
function shutdownPools() {
  return Promise.all(
    Object.values(SESSION_POOLS).map((pool) =>
      pool.shutdown().catch(() => {}),
    ),
  );
}

// `resumeId` continues that session; when null a brand-new one is started. The
// resolved session id is persisted under `sessionKey`.
function runClaude(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const resumeId = prior && prior.id ? prior.id : null;
  const resuming = !!resumeId;
  // Resume reuses the saved session ID; a new conversation gets its id from
  // the CLI's first message and persists it once the turn succeeds.
  let sessionId = resuming ? resumeId : null;
  let finalText = '';
  let isError = false;
  // A turn can contain several assistant messages (Claude's mid-task follow-up
  // notes, then a final summary). Each distinct message id marks a new segment;
  // emitting a `segment` boundary lets the app keep every message with its own
  // timestamp instead of collapsing them into the final result text.
  let emitDelta = makeDeltaEmitter(onEvent);
  let currentMsgId = null;

  // model / effort / permission for this scope. claudeSdkOptions resolves the
  // permission tier too; an unconfigured scope defaults to the acceptEdits
  // "auto" tier, not full bypass. These are fixed for the life of a session
  // process, so the pool restarts (and resumes) when they change.
  const sdkOptions = claudeSdkOptions(settings);

  const onMessage = (event) => {
    if (event.session_id) sessionId = event.session_id;
    if (
      event.type === 'assistant' &&
      event.message &&
      Array.isArray(event.message.content)
    ) {
      const msgId = event.message.id || 'msg';
      if (currentMsgId !== null && msgId !== currentMsgId) {
        // Claude moved on to a fresh follow-up message in the same turn.
        emit(onEvent, { type: 'segment' });
        emitDelta = makeDeltaEmitter(onEvent);
      }
      currentMsgId = msgId;
      for (const block of event.message.content) {
        if (block.type === 'text' && block.text) {
          emitDelta(block.text);
          emit(onEvent, `Claude: ${oneLine(block.text)}`);
        } else if (block.type === 'tool_use') {
          emit(onEvent, `Tool: ${toolBrief(block.name, block.input)}`);
        }
      }
    }
  };

  const finalize = (stderr) => {
    const error = String(stderr || '').trim();
    if (finalText.trim()) {
      if (!isError && sessionKey) setSession(sessionKey, { id: sessionId });
      if (isError && isAuthError(finalText)) return { __authError: true };
      return `${isError ? 'Claude returned an error:\n' : ''}${finalText.trim()}`;
    }
    // Resume can fail if the CLI removed an old session. Drop it and retry.
    if (
      resuming &&
      /no conversation|session.*(not found|does not exist)|no such session|could not find/i.test(
        error,
      )
    ) {
      if (sessionKey) clearSession(sessionKey);
      return { __retry: true };
    }
    if (isAuthError(error)) return { __authError: true };
    return error || '(claude produced no output)';
  };

  const run = claudePool
    .send({
      key: sessionKey || `claude:${cwd}`,
      prompt: String(prompt),
      cwd,
      sdkOptions,
      // Any change to the resolved options means the live process is running
      // the wrong configuration and has to be replaced.
      optionsKey: JSON.stringify(sdkOptions),
      resumeId,
      executablePath: claudeExecutablePath(),
      signal,
      onMessage,
    })
    .then(
      ({ result, sessionId: resolvedId, stderr }) => {
        if (resolvedId) sessionId = resolvedId;
        if (typeof result.result === 'string') finalText = result.result;
        // A timed-out turn reports the stop reason as the reply, not as a
        // Claude error.
        if (
          result.subtype &&
          result.subtype !== 'success' &&
          result.subtype !== 'timeout'
        ) {
          isError = true;
        }
        return finalize(stderr);
      },
      (err) => {
        if (err && err.code === 'AGENT_CANCELLED') throw new AgentCancelledError();
        return finalize(err && err.message);
      },
    );

  return finishRun(run, {
    agentKey: 'claude',
    onEvent,
    retry: () =>
      runClaude(prompt, onEvent, sessionKey, signal, workdir, settings),
  });
}

// The app-server names item types in camelCase; `codex exec --json` used
// snake_case. Both spellings are accepted so the labels survive either.
function codexItemLabel(item) {
  const type = item.type || item.item_type;
  if (type === 'commandExecution' || type === 'command_execution') {
    const command = Array.isArray(item.command)
      ? item.command.join(' ')
      : item.command || '';
    return `Command: ${oneLine(command, 80)}`;
  }
  if (type === 'fileChange' || type === 'file_change' || type === 'patch_apply') {
    return 'File change';
  }
  if (type === 'agentMessage' || type === 'agent_message') {
    return `Codex: ${oneLine(item.text || '')}`;
  }
  if (type === 'reasoning') return null;
  if (type === 'mcpToolCall' || type === 'mcp_tool_call') {
    return `MCP: ${oneLine(item.tool || item.name || '', 60)}`;
  }
  if (type === 'webSearch' || type === 'web_search') {
    return `Search: ${oneLine(item.query || '', 60)}`;
  }
  return null;
}

// codex runs as a persistent app-server thread (see codex-session-pool.js):
// one process hosts every chat, `turn/start` carries a turn, and the reply
// arrives as `item/agentMessage/delta` notifications. Every setting except the
// sandbox applies per turn, so only a sandbox change reopens the thread — and
// that still resumes the same conversation.
function runCodex(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const resumeId = (prior && prior.id) || null;
  const options = codexSessionOptions(settings);
  // Accumulate the streamed text so a single-message turn has an authoritative
  // result; multi-message turns are rebuilt from segments by agent-turn.
  let finalText = '';
  let currentItemId = null;

  const onMessage = (event) => {
    if (event.type === 'delta') {
      // Codex can emit several agent messages in one turn; each new item id
      // starts a segment so follow-ups keep their own timestamp.
      if (currentItemId !== null && event.itemId !== currentItemId) {
        emit(onEvent, { type: 'segment' });
      }
      currentItemId = event.itemId;
      if (!event.text) return;
      finalText += event.text;
      emit(onEvent, { type: 'delta', text: event.text });
      return;
    }
    const label = codexItemLabel(event.item);
    if (label) emit(onEvent, label);
  };

  // Relay pins approvals off on every tier, so this is only a backstop against
  // a turn hanging on a prompt nobody can answer.
  const onPermission = ({ title }) => {
    if (options.approve) return true;
    emit(onEvent, `Blocked (needs approval): ${oneLine(title, 60)}`);
    return false;
  };

  const run = codexPool
    .send({
      key: sessionKey || `codex:${cwd}`,
      prompt: String(prompt),
      cwd,
      resumeId,
      // Only the sandbox is fixed when a thread is opened.
      fixedKey: options.sandbox,
      ...options,
      signal,
      onMessage,
      onPermission,
    })
    .then(
      ({ result, sessionId, startedNew, stderr }) => {
        if (startedNew) {
          emit(onEvent, 'The old session is no longer valid. Started a new one.');
        }
        if (finalText.trim()) {
          if (sessionId) setSession(sessionKey, { id: sessionId });
          return finalText.trim();
        }
        if (result.stopReason === 'timeout') return result.message;
        if (isAuthError(stderr)) return { __authError: true };
        return errorLines(stderr) || '(codex produced no output)';
      },
      (err) => {
        if (err && err.code === 'AGENT_CANCELLED') throw new AgentCancelledError();
        const message = (err && err.message) || '';
        const stderr = (err && err.stderr) || '';
        if (isAuthError(message) || isAuthError(stderr)) {
          return { __authError: true };
        }
        return (
          [message, errorLines(stderr)].filter(Boolean).join('\n').trim() ||
          '(codex produced no output)'
        );
      },
    );

  return finishRun(run, { agentKey: 'codex', onEvent });
}

// Agents log freely to stderr, so when a turn produced no text at all the tail
// is the only clue — but routine INFO chatter is not an error message, and
// dumping it as the assistant's reply would be worse than saying nothing.
function errorLines(text) {
  return String(text || '')
    .split(/\r?\n/)
    .filter((line) => /error|fatal|critical|traceback|exception/i.test(line))
    .slice(-5)
    .join('\n')
    .trim();
}

// opencode and hermes both run as persistent ACP sessions (see
// acp-session-pool.js): one process hosts every chat, `session/prompt` carries
// a turn, and the reply arrives as `agent_message_chunk` updates — real
// token-level streaming, where the old per-turn CLI paths could stream whole
// JSON lines at best (hermes could not stream at all). A new messageId inside
// one turn marks a follow-up message (segment).
function runAcpAgent({
  agentKey,
  pool,
  prompt,
  onEvent,
  sessionKey,
  signal,
  workdir,
  settings,
}) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const resumeId = (prior && prior.id) || null;
  // model and mode are applied to the live session over the protocol; `approve`
  // decides how Relay answers the agent's approval requests.
  const { modelId, modeId, approve } = acpSessionOptions(agentKey, settings);
  // Accumulate the streamed text so a single-message turn has an authoritative
  // result; multi-message turns are rebuilt from segments by agent-turn.
  let finalText = '';
  let currentMsgId = null;

  // ACP chunks are already deltas, so they are emitted as-is rather than
  // through makeDeltaEmitter (whose prefix de-duplication is for CLIs that
  // re-send the whole message each time, and would drop a repeated token).
  const pushText = (text) => {
    if (!text) return;
    finalText += text;
    emit(onEvent, { type: 'delta', text });
  };

  const onMessage = (update) => {
    if (update.sessionUpdate === 'agent_message_chunk') {
      const msgId = update.messageId || 'msg';
      if (currentMsgId !== null && msgId !== currentMsgId) {
        emit(onEvent, { type: 'segment' });
      }
      currentMsgId = msgId;
      const content = update.content || {};
      if (content.type === 'text') pushText(content.text);
    } else if (update.sessionUpdate === 'tool_call') {
      emit(onEvent, `Tool: ${oneLine(update.title || update.kind || 'tool', 60)}`);
    }
  };

  // Relay has no approval UI, so a permission request is answered from the
  // configured tier instead of being left to hang a turn nobody can unblock.
  // The answer is yes or no; the driver picks the option that says so.
  const onPermission = ({ title }) => {
    if (approve) return true;
    emit(onEvent, `Blocked (needs approval): ${oneLine(title, 60)}`);
    return false;
  };

  const noOutput = `(${agentKey} produced no output)`;
  const run = pool
    .send({
      key: sessionKey || `${agentKey}:${cwd}`,
      prompt: String(prompt),
      cwd,
      resumeId,
      modelId,
      modeId,
      signal,
      onMessage,
      onPermission,
    })
    .then(
      ({ result, sessionId, startedNew, stderr }) => {
        if (startedNew) {
          emit(onEvent, 'The old session is no longer valid. Started a new one.');
        }
        if (finalText.trim()) {
          if (sessionId) setSession(sessionKey, { id: sessionId });
          return finalText.trim();
        }
        if (result.stopReason === 'timeout') return result.message;
        if (isAuthError(stderr)) return { __authError: true };
        return errorLines(stderr) || noOutput;
      },
      (err) => {
        if (err && err.code === 'AGENT_CANCELLED') throw new AgentCancelledError();
        const message = (err && err.message) || '';
        const stderr = (err && err.stderr) || '';
        if (isAuthError(message) || isAuthError(stderr)) {
          return { __authError: true };
        }
        return (
          [message, errorLines(stderr)].filter(Boolean).join('\n').trim() ||
          noOutput
        );
      },
    );

  return finishRun(run, { agentKey, onEvent });
}

function runOpencode(prompt, onEvent, sessionKey, signal, workdir, settings) {
  return runAcpAgent({
    agentKey: 'opencode',
    pool: opencodePool,
    prompt,
    onEvent,
    sessionKey,
    signal,
    workdir,
    settings,
  });
}

function runHermes(prompt, onEvent, sessionKey, signal, workdir, settings) {
  return runAcpAgent({
    agentKey: 'hermes',
    pool: hermesPool,
    prompt,
    onEvent,
    sessionKey,
    signal,
    workdir,
    settings,
  });
}

const AGENTS = {
  claude: {
    key: 'claude',
    label: 'Claude Code',
    description: 'Anthropic Claude Code CLI',
    run: runClaude,
  },
  codex: {
    key: 'codex',
    label: 'Codex',
    description: 'OpenAI Codex CLI',
    run: runCodex,
  },
  // Experimental: listed in the app with explicit install/auth status.
  opencode: {
    key: 'opencode',
    label: 'OpenCode',
    description: 'OpenCode CLI',
    run: runOpencode,
    bin: 'opencode',
    experimental: true,
  },
  hermes: {
    key: 'hermes',
    label: 'Hermes',
    description: 'Hermes CLI',
    run: runHermes,
    bin: 'hermes',
    experimental: true,
  },
};

const DEFAULT_AGENT = 'claude';

function listAgents() {
  return Object.values(AGENTS).map(({ key, label, description }) => ({
    key,
    label,
    description,
  }));
}

function getAgent(key) {
  return AGENTS[key] || null;
}

async function runAgent(agentKey, prompt, onEvent, options = {}) {
  const agent = getAgent(agentKey);
  if (!agent) {
    throw new Error(`Unknown agent: ${agentKey}`);
  }
  const sessionKey = options.sessionKey || agent.key;
  return agent.run(
    prompt,
    onEvent,
    sessionKey,
    options.signal,
    options.workdir,
    options.settings,
  );
}

module.exports = {
  AGENTS,
  AgentCancelledError,
  AgentAuthError,
  DEFAULT_AGENT,
  TIMEOUT_MS,
  listAgents,
  getAgent,
  commandExists,
  runAgent,
  getSession,
  clearSession,
  purgeSession,
  shutdownPools,
  claudePool,
  opencodePool,
  hermesPool,
  codexPool,
};
