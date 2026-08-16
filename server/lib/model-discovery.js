'use strict';

// Dynamic model discovery: read the model list each agent CLI actually ships so
// the picker tracks the installed binary instead of a hand-maintained catalog.
// When a CLI updates (e.g. `claude update` adds Fable 5), the new models appear
// here automatically — no code change.
//
// Each strategy returns model options (newest first, optionally with per-model
// effort metadata) or null when discovery is unavailable; agent-options falls
// back to its static catalog in that case. Results are cached per agent and
// keyed by the resolved binary plus relevant CLI cache files, so an update busts
// the cache while steady-state calls stay a cheap map lookup.
//
// Set RELAY_MODEL_DISCOVERY=0 to disable and always use the static catalog.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const DISABLED =
  process.env.RELAY_MODEL_DISCOVERY === '0' ||
  process.env.RELAY_MODEL_DISCOVERY === 'false';

// agentKey -> { stamp, models }. models is a non-empty array or null; both are
// cached so a missing/empty result never re-spawns on every turn.
const cache = new Map();

// Resolve a command name to its real (symlink-followed) absolute path, or null.
function resolveBinary(command) {
  try {
    const win = process.platform === 'win32';
    const result = spawnSync(win ? 'where' : 'command', win ? [command] : ['-v', command], {
      encoding: 'utf8',
      shell: !win,
      timeout: 3000,
    });
    const line = String(result.stdout || '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean)[0];
    return line ? fs.realpathSync(line) : null;
  } catch (_err) {
    return null;
  }
}

function fileStamp(filePath) {
  try {
    const s = fs.statSync(filePath);
    return `${filePath}:${s.size}:${s.mtimeMs}`;
  } catch (_err) {
    return null;
  }
}

// Stream a (potentially large, ~250MB) binary in chunks, collecting every match
// of `regex` without loading the whole file into memory. A short tail overlap
// between chunks keeps a token from being missed at a boundary.
function scanFile(filePath, regex) {
  const found = new Set();
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const CHUNK = 1 << 20; // 1 MiB
    const buf = Buffer.allocUnsafe(CHUNK);
    let tail = '';
    let position = 0;
    let bytesRead;
    while ((bytesRead = fs.readSync(fd, buf, 0, CHUNK, position)) > 0) {
      position += bytesRead;
      const text = tail + buf.toString('latin1', 0, bytesRead);
      let match;
      regex.lastIndex = 0;
      while ((match = regex.exec(text)) !== null) found.add(match[0]);
      tail = text.slice(-64);
    }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  return found;
}

// ---- claude -----------------------------------------------------------------

const CLAUDE_FAMILY_LABEL = {
  opus: 'Opus',
  sonnet: 'Sonnet',
  haiku: 'Haiku',
  fable: 'Fable',
};
const CLAUDE_FAMILY_ORDER = ['opus', 'sonnet', 'haiku', 'fable'];
const CLAUDE_ID_RE = /claude-(?:opus|sonnet|haiku|fable)-\d+(?:-\d+)*/g;

// Collapse the many raw ids (dated snapshots, -v1, -fast, -0 aliases) into one
// canonical "family major[.minor]" entry each, e.g. claude-opus-4-1-20250805
// and claude-opus-4-1 both fold to claude-opus-4-1 / "Opus 4.1".
function parseClaudeModels(raw) {
  const byId = new Map();
  for (const token of raw) {
    const m = /^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)*)$/.exec(token);
    if (!m) continue;
    const family = m[1];
    const parts = m[2].split('-');
    const major = parts[0];
    let minor = parts[1];
    // A real minor is 1-2 digits; an 8-digit group is a date snapshot, and a
    // trailing 0 (4-0) is just the base version.
    if (minor === undefined || minor.length > 2 || minor === '0') minor = null;
    const id = minor
      ? `claude-${family}-${major}-${minor}`
      : `claude-${family}-${major}`;
    if (byId.has(id)) continue;
    byId.set(id, {
      id,
      label: `${CLAUDE_FAMILY_LABEL[family]} ${major}${minor ? `.${minor}` : ''}`,
      args: ['--model', id],
      _sort: [CLAUDE_FAMILY_ORDER.indexOf(family), Number(major), Number(minor || 0)],
    });
  }
  return sortByFamilyThenVersionDesc([...byId.values()]);
}

// ---- codex -------------------------------------------------------------------

const SAFE_MODEL_ID_RE = /^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,127}$/;
const SAFE_EFFORT_ID_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

function optionLabel(id) {
  if (id === 'xhigh') return 'Extra high';
  return id
    .split(/[-_]/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

// `codex debug models` and app-server's `model/list` expose the same catalog in
// snake_case and camelCase respectively. Accept both shapes so discovery stays
// coupled to Codex's structured metadata rather than guessing ids from strings
// embedded in the binary. Each model keeps its own ordered reasoning choices.
function parseCodexCatalog(raw) {
  let parsed = raw;
  if (typeof raw === 'string') {
    try {
      parsed = JSON.parse(raw);
    } catch (_err) {
      return [];
    }
  }
  const entries = Array.isArray(parsed && parsed.models)
    ? parsed.models
    : Array.isArray(parsed && parsed.data)
      ? parsed.data
      : [];
  const models = [];
  const seen = new Set();
  for (let index = 0; index < entries.length; index += 1) {
    const item = entries[index];
    if (!item || typeof item !== 'object') continue;
    if (item.visibility && item.visibility !== 'list') continue;
    if (item.hidden === true) continue;
    const id = String(item.slug || item.id || item.model || '').trim();
    const cliModel = String(item.slug || item.model || item.id || '').trim();
    if (
      !SAFE_MODEL_ID_RE.test(id) ||
      !SAFE_MODEL_ID_RE.test(cliModel) ||
      seen.has(id)
    ) {
      continue;
    }

    const rawEfforts = Array.isArray(item.supported_reasoning_levels)
      ? item.supported_reasoning_levels
      : Array.isArray(item.supportedReasoningEfforts)
        ? item.supportedReasoningEfforts
        : [];
    const efforts = [];
    const seenEfforts = new Set();
    for (const rawEffort of rawEfforts) {
      const effort = String(
        rawEffort && (rawEffort.effort || rawEffort.reasoningEffort) || '',
      ).trim();
      if (!SAFE_EFFORT_ID_RE.test(effort) || seenEfforts.has(effort)) continue;
      seenEfforts.add(effort);
      efforts.push({
        id: effort,
        label: optionLabel(effort),
        description:
          typeof rawEffort.description === 'string'
            ? rawEffort.description.trim() || undefined
            : undefined,
        args: ['-c', `model_reasoning_effort=${effort}`],
      });
    }
    const requestedDefault = String(
      item.default_reasoning_level || item.defaultReasoningEffort || '',
    ).trim();
    const defaultEffort = efforts.some((effort) => effort.id === requestedDefault)
      ? requestedDefault
      : efforts[0] && efforts[0].id;

    seen.add(id);
    models.push({
      id,
      label: String(item.display_name || item.displayName || id).trim() || id,
      description:
        typeof item.description === 'string'
          ? item.description.trim() || undefined
          : undefined,
      args: ['-m', cliModel],
      efforts,
      defaultEffort,
      _priority:
        Number.isFinite(Number(item.priority)) ? Number(item.priority) : index,
      _isDefault: item.isDefault === true,
      _index: index,
    });
  }
  models.sort(
    (a, b) =>
      Number(b._isDefault) - Number(a._isDefault) ||
      a._priority - b._priority ||
      a._index - b._index,
  );
  return models.map(({ _priority, _isDefault, _index, ...model }) => model);
}

function codexHome() {
  const configured = String(process.env.CODEX_HOME || '').trim();
  return configured || path.join(os.homedir(), '.codex');
}

function readCodexCache({ maxAgeMs } = {}) {
  try {
    const parsed = JSON.parse(
      fs.readFileSync(path.join(codexHome(), 'models_cache.json'), 'utf8'),
    );
    const cacheVersion = String(parsed.client_version || '').trim();
    if (!cacheVersion) return [];
    const versionResult = spawnSync('codex', ['--version'], {
      encoding: 'utf8',
      timeout: 3000,
    });
    const match = String(versionResult.stdout || '').match(
      /\d+\.\d+\.\d+(?:[-+][^\s]+)?/,
    );
    if (versionResult.status !== 0 || !match || match[0] !== cacheVersion) {
      return [];
    }
    if (Number.isFinite(maxAgeMs)) {
      const fetchedAt = Date.parse(String(parsed.fetched_at || ''));
      if (!Number.isFinite(fetchedAt) || Date.now() - fetchedAt > maxAgeMs) {
        return [];
      }
    }
    return parseCodexCatalog(parsed);
  } catch (_err) {
    return [];
  }
}

function runCodexCatalog(args, timeout = 5000) {
  const result = spawnSync('codex', args, {
    encoding: 'utf8',
    timeout,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) return [];
  return parseCodexCatalog(String(result.stdout || ''));
}

// ---- shared helpers ----------------------------------------------------------

function sortByFamilyThenVersionDesc(list) {
  list.sort(
    (a, b) =>
      a._sort[0] - b._sort[0] ||
      b._sort[1] - a._sort[1] ||
      b._sort[2] - a._sort[2],
  );
  return list.map(({ _sort, ...rest }) => rest);
}

// `codex` on PATH is normally a thin JS launcher. Stamp the per-platform Rust
// binary inside the package so an npm update invalidates discovery even when the
// launcher's path remains unchanged.
function locateCodexBinary() {
  const launcher = resolveBinary('codex');
  if (!launcher) return null;
  const pkgRoot = path.dirname(path.dirname(launcher));
  const vendorParent = path.join(pkgRoot, 'node_modules', '@openai');
  let scopes;
  try {
    scopes = fs.readdirSync(vendorParent);
  } catch (_err) {
    return launcher;
  }
  for (const name of scopes) {
    if (!name.startsWith('codex-')) continue;
    const vendorDir = path.join(vendorParent, name, 'vendor');
    let targets;
    try {
      targets = fs.readdirSync(vendorDir);
    } catch (_err) {
      continue;
    }
    for (const target of targets) {
      for (const exe of ['codex', 'codex.exe']) {
        const candidate = path.join(vendorDir, target, 'bin', exe);
        if (fs.existsSync(candidate)) return fs.realpathSync(candidate);
      }
    }
  }
  return launcher;
}

const STRATEGIES = {
  claude: {
    locate: () => resolveBinary('claude'),
    discover: (bin) => {
      const list = parseClaudeModels(scanFile(bin, CLAUDE_ID_RE));
      return list.length ? list : null;
    },
  },
  codex: {
    locate: () => locateCodexBinary(),
    discover: () => {
      const freshCache = readCodexCache({ maxAgeMs: 5 * 60 * 1000 });
      if (freshCache.length) return freshCache;
      const live = runCodexCatalog(['debug', 'models'], 5000);
      if (live.length) return live;
      const bundled = runCodexCatalog(
        ['debug', 'models', '--bundled'],
        3000,
      );
      if (bundled.length) return bundled;
      const cached = readCodexCache();
      return cached.length ? cached : null;
    },
  },
};

// Discovered model options for an agent, or null to fall back to the static
// catalog. Cached by binary/cache stamps so CLI and catalog updates refresh it.
function discoverModels(agentKey) {
  if (DISABLED) return null;
  const strategy = STRATEGIES[agentKey];
  if (!strategy) return null;
  try {
    const bin = strategy.locate();
    if (!bin) return null;
    const extraStamp =
      agentKey === 'codex'
        ? fileStamp(path.join(codexHome(), 'models_cache.json')) || ''
        : '';
    const stamp = `${fileStamp(bin) || ''}|${extraStamp}`;
    const cached = cache.get(agentKey);
    if (cached && cached.stamp === stamp) return cached.models;
    let models = null;
    try {
      models = strategy.discover(bin);
    } catch (_err) {
      models = null;
    }
    const normalized = Array.isArray(models) && models.length ? models : null;
    const finalExtraStamp =
      agentKey === 'codex'
        ? fileStamp(path.join(codexHome(), 'models_cache.json')) || ''
        : '';
    const finalStamp = `${fileStamp(bin) || ''}|${finalExtraStamp}`;
    cache.set(agentKey, { stamp: finalStamp, models: normalized });
    return normalized;
  } catch (_err) {
    return null;
  }
}

function clearModelDiscoveryCache(agentKey) {
  if (agentKey) cache.delete(agentKey);
  else cache.clear();
}

module.exports = {
  clearModelDiscoveryCache,
  discoverModels,
  parseCodexCatalog,
};
