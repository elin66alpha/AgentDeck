'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// Per-device work directory. Each client carries its own current path via the
// `x-workdir` request header, so two devices can work in different paths at the
// same time. This module only validates, resolves, and creates paths; there is
// no shared "current workdir" state anymore. The `.env` RELAY_DEFAULT_DIR is
// kept solely as an optional override for the default a brand-new device starts
// from. Session identity is keyed by workdir + agent + chat session in server.js.
const ENV_PATH = path.join(__dirname, '..', '.env');

class WorkdirError extends Error {
  constructor(message, { code, status = 400, dir } = {}) {
    super(message);
    this.name = 'WorkdirError';
    this.code = code;
    this.status = status;
    this.dir = dir;
  }
}

function expandWorkdir(value) {
  const raw = String(value || '').trim();
  if (!raw) return path.join(os.homedir(), 'Relay');
  if (raw === '~') return os.homedir();
  if (raw.startsWith('~/')) return path.join(os.homedir(), raw.slice(2));
  return raw;
}

function resolveWorkdir(value) {
  const raw = String(value || '').trim();
  if (!raw) {
    throw new WorkdirError('workdir path is required', {
      code: 'WORKDIR_PATH_REQUIRED',
    });
  }
  const expanded = expandWorkdir(raw);
  if (!path.isAbsolute(expanded)) {
    throw new WorkdirError('workdir must be an absolute path', {
      code: 'WORKDIR_NOT_ABSOLUTE',
      dir: raw,
    });
  }
  const resolved = path.resolve(expanded);
  if (resolved === path.parse(resolved).root) {
    throw new WorkdirError('workdir cannot be the filesystem root', {
      code: 'WORKDIR_ROOT_NOT_ALLOWED',
      dir: resolved,
    });
  }
  return resolved;
}

// The path a brand-new device (one that has not chosen a workdir yet) starts
// from. Comes from RELAY_DEFAULT_DIR when set, otherwise ~/Relay.
function getDefaultWorkdir() {
  return process.env.RELAY_DEFAULT_DIR
    ? resolveWorkdir(process.env.RELAY_DEFAULT_DIR)
    : resolveWorkdir(expandWorkdir(''));
}

function ensureWorkdirExists(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  return dir;
}

// Resolve the workdir for a request: the device's `x-workdir` header when
// present, otherwise the default. The path is created if missing so agent
// execution and file browsing always have a real cwd. Returns the canonical
// absolute path, which is also the basis of the session scope key.
function resolveRequestWorkdir(value) {
  const raw = String(value || '').trim();
  const dir = raw ? resolveWorkdir(raw) : getDefaultWorkdir();
  return ensureWorkdirExists(dir);
}

function inspectWorkdir(value) {
  const dir = resolveWorkdir(value);
  let exists = false;
  let isDirectory = false;
  try {
    const stat = fs.statSync(dir);
    exists = true;
    isDirectory = stat.isDirectory();
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  return { dir, exists, isDirectory };
}

// Validate a path the user wants to switch to, optionally creating it. Unlike
// the old setWorkdir this persists no global state: the client stores its own
// choice locally and sends it back via the x-workdir header. Returns the
// canonical path so the client can persist exactly what the backend resolved.
function validateWorkdir(value, { create = false } = {}) {
  const info = inspectWorkdir(value);
  if (info.exists && !info.isDirectory) {
    throw new WorkdirError('workdir path exists but is not a directory', {
      code: 'WORKDIR_NOT_DIRECTORY',
      status: 400,
      dir: info.dir,
    });
  }
  let created = false;
  if (!info.exists) {
    if (!create) {
      throw new WorkdirError('workdir path does not exist', {
        code: 'WORKDIR_NOT_FOUND',
        status: 404,
        dir: info.dir,
      });
    }
    fs.mkdirSync(info.dir, { recursive: true });
    created = true;
  }
  return { dir: info.dir, created };
}

module.exports = {
  WorkdirError,
  resolveWorkdir,
  getDefaultWorkdir,
  ensureWorkdirExists,
  resolveRequestWorkdir,
  inspectWorkdir,
  validateWorkdir,
  ENV_PATH,
};
