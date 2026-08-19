'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const { getDefaultWorkdir, ensureWorkdirExists } = require('./workdir');
const { TOKENS_FILE } = require('./tokens');

class FilesystemError extends Error {
  constructor(message, { status = 400, code = 'FS_ERROR' } = {}) {
    super(message);
    this.name = 'FilesystemError';
    this.status = status;
    this.code = code;
  }
}

function isInside(parent, child) {
  return child === parent || child.startsWith(`${parent}${path.sep}`);
}

// --- access policy ------------------------------------------------------------
//
// The file API is deliberately filesystem-wide (the unified browser can reach
// anything the server user can), but a leaked device token must not be able to
// escalate: reading tokens.json/.env mints new credentials, and reading the CLI
// auth files or ~/.ssh takes over accounts beyond Relay. Those paths are always
// refused, for download, upload, and listing alike. Everything else stays
// reachable unless RELAY_FS_ROOTS narrows the API to an explicit allowlist
// (comma-separated absolute paths); agent execution is not affected either way.

const SERVER_DIR = path.resolve(__dirname, '..');

const SENSITIVE_PATHS = [
  // Taken from tokens.js rather than rebuilt here, so RELAY_TOKENS_FILE cannot
  // move the token store out from under the denylist.
  TOKENS_FILE,
  path.join(SERVER_DIR, '.env'),
  path.join(SERVER_DIR, 'credentials'),
  path.join(SERVER_DIR, 'push-subscriptions.json'),
  path.join(SERVER_DIR, 'fcm-tokens.json'),
  path.join(os.homedir(), '.ssh'),
  path.join(os.homedir(), '.claude', '.credentials.json'),
  path.join(os.homedir(), '.codex', 'auth.json'),
];

const FS_ROOTS = String(process.env.RELAY_FS_ROOTS || '')
  .split(',')
  .map((entry) => entry.trim())
  .filter(Boolean)
  .map((entry) => path.resolve(entry));

function restrictedError() {
  return new FilesystemError('path is restricted', {
    status: 403,
    code: 'FS_PATH_RESTRICTED',
  });
}

// Refuse a target that is a sensitive path, lives inside one, or is one of the
// atomic-write temp files beside one. When RELAY_FS_ROOTS is set, the target
// must also fall under one of the configured roots.
function assertPathAllowed(target) {
  const resolved = path.resolve(target);
  for (const sensitive of SENSITIVE_PATHS) {
    if (isInside(sensitive, resolved) || resolved === `${sensitive}.tmp`) {
      throw restrictedError();
    }
  }
  if (FS_ROOTS.length && !FS_ROOTS.some((root) => isInside(root, resolved))) {
    throw new FilesystemError('path is outside the allowed roots', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_ROOTS',
    });
  }
}

// Directory downloads additionally refuse trees that *contain* a sensitive path
// — zipping the server directory (or any ancestor) would otherwise exfiltrate
// tokens.json inside the archive.
function assertTreeAllowed(target) {
  assertPathAllowed(target);
  const resolved = path.resolve(target);
  for (const sensitive of SENSITIVE_PATHS) {
    if (isInside(resolved, sensitive)) {
      throw restrictedError();
    }
  }
}

function normalizeRelative(input) {
  const text = String(input || '').trim().replace(/\\/g, '/');
  if (!text || text === '.') return '';
  if (path.isAbsolute(text)) {
    throw new FilesystemError('file browser paths must be relative to workdir', {
      status: 400,
      code: 'FS_PATH_MUST_BE_RELATIVE',
    });
  }
  const normalized = path.posix.normalize(text);
  if (normalized === '.' || normalized === '/') return '';
  if (normalized === '..' || normalized.startsWith('../')) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  return normalized;
}

function toApiPath(root, target) {
  return path.relative(root, target).split(path.sep).filter(Boolean).join('/');
}

function currentRoot(workdir) {
  const root = path.resolve(ensureWorkdirExists(workdir));
  const realRoot = fs.realpathSync(root);
  return { root, realRoot };
}

function resolveExisting(relativePath, workdir) {
  const { root, realRoot } = currentRoot(workdir);
  const relative = normalizeRelative(relativePath);
  const target = path.resolve(root, relative);
  if (!isInside(root, target)) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  let stat;
  let realTarget;
  try {
    stat = fs.statSync(target);
    realTarget = fs.realpathSync(target);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!isInside(realRoot, realTarget)) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  assertPathAllowed(realTarget);
  return {
    root,
    realRoot,
    target,
    realTarget,
    relative: toApiPath(root, target),
    stat,
  };
}

async function entryFor(root, target, dirent, { absolutePaths = false } = {}) {
  const stat = await fs.promises.lstat(target);
  let type = 'other';
  if (stat.isDirectory()) {
    type = 'directory';
  } else if (stat.isFile()) {
    type = 'file';
  }
  return {
    name: dirent.name,
    path: absolutePaths ? target : toApiPath(root, target),
    absolutePath: target,
    type,
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
  };
}

async function visibleDirents(target, { showHidden = false } = {}) {
  const dirents = await fs.promises.readdir(target, { withFileTypes: true });
  return dirents.filter((dirent) => showHidden || !dirent.name.startsWith('.'));
}

function sortEntries(entries) {
  return entries.sort((a, b) => {
    if (a.type === 'directory' && b.type !== 'directory') return -1;
    if (a.type !== 'directory' && b.type === 'directory') return 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
  });
}

async function listAbsoluteDirectory(value, { showHidden = false, fallbackDir } = {}) {
  const raw = String(value || '').trim();
  if (raw && !path.isAbsolute(raw)) {
    throw new FilesystemError('directory browser path must be absolute', {
      status: 400,
      code: 'FS_PATH_MUST_BE_ABSOLUTE',
    });
  }
  const target = path.resolve(raw || fallbackDir || getDefaultWorkdir());
  let stat;
  try {
    stat = await fs.promises.stat(target);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!stat.isDirectory()) {
    throw new FilesystemError('path is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  assertPathAllowed(target);
  const root = path.parse(target).root;
  const dirents = await visibleDirents(target, { showHidden });
  const entries = sortEntries(
    (
      await Promise.all(
        dirents.map((dirent) =>
          entryFor(root, path.join(target, dirent.name), dirent, {
            absolutePaths: true,
          }).catch(() => null),
        ),
      )
    ).filter(Boolean),
  );
  return {
    root,
    path: target,
    absolutePath: target,
    parentPath: target === root ? null : path.dirname(target),
    entries,
  };
}

// Recursively sum the size of every regular file under `dir`. Symlinks are
// skipped so the walk cannot loop or escape via a linked directory. Used to
// reject directory (zip) downloads before we start streaming, since the tunnel
// has a hard size budget and a half-sent zip cannot become a clean error.
// Async + yielding between syscalls so walking a large tree (e.g. node_modules)
// does not block the single-threaded server for every other client and agent.
async function directorySize(dir) {
  let total = 0;
  const stack = [dir];
  while (stack.length) {
    const current = stack.pop();
    let dirents;
    try {
      dirents = await fs.promises.readdir(current, { withFileTypes: true });
    } catch (_err) {
      continue;
    }
    for (const dirent of dirents) {
      // The dirent already classifies the entry without following symlinks, so
      // we only need a stat for the size of regular files.
      if (dirent.isSymbolicLink()) continue;
      const full = path.join(current, dirent.name);
      if (dirent.isDirectory()) {
        stack.push(full);
      } else if (dirent.isFile()) {
        try {
          total += (await fs.promises.lstat(full)).size;
        } catch (_err) {
          // Skip entries that vanish or can't be stat'd mid-walk.
        }
      }
    }
  }
  return total;
}

// Download by absolute path so the unified file browser can fetch anything the
// user can navigate to (the browser already exposes the whole filesystem up to
// root). `maxBytes`, when set, caps the download: a single file by its size, a
// directory by its uncompressed total (which is >= the resulting zip, so the
// zip is guaranteed to fit). Over-limit throws before any bytes are streamed.
async function prepareDownloadAbsolute(value, { maxBytes } = {}) {
  const raw = String(value || '').trim();
  if (!raw || !path.isAbsolute(raw)) {
    throw new FilesystemError('download path must be absolute', {
      status: 400,
      code: 'FS_PATH_MUST_BE_ABSOLUTE',
    });
  }
  const target = path.resolve(raw);
  let stat;
  try {
    stat = await fs.promises.stat(target);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!stat.isFile() && !stat.isDirectory()) {
    throw new FilesystemError('only files and directories can be downloaded', {
      status: 400,
      code: 'FS_UNSUPPORTED_DOWNLOAD',
    });
  }
  const isDirectory = stat.isDirectory();
  if (isDirectory) assertTreeAllowed(target);
  else assertPathAllowed(target);
  const totalBytes = isDirectory ? await directorySize(target) : stat.size;
  if (typeof maxBytes === 'number' && maxBytes > 0 && totalBytes > maxBytes) {
    throw new FilesystemError('download exceeds the size limit', {
      status: 413,
      code: 'FS_DOWNLOAD_TOO_LARGE',
      meta: { totalBytes, maxBytes },
    });
  }
  const basename = path.basename(target) || 'download';
  return {
    target,
    isDirectory,
    totalBytes,
    filename: isDirectory ? `${basename}.zip` : basename,
    zipCwd: path.dirname(target),
    zipEntryName: basename,
  };
}

// Upload into an absolute directory chosen in the unified file browser. Mirrors
// resolveUploadTarget but without the workdir confinement, matching the
// browser's whole-filesystem reach. The filename is still sanitised to a bare
// basename so it cannot traverse out of the chosen directory.
function resolveAbsoluteUploadTarget(value, filename) {
  const raw = String(value || '').trim();
  if (!raw || !path.isAbsolute(raw)) {
    throw new FilesystemError('upload path must be absolute', {
      status: 400,
      code: 'FS_PATH_MUST_BE_ABSOLUTE',
    });
  }
  const directory = path.resolve(raw);
  let stat;
  try {
    stat = fs.statSync(directory);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!stat.isDirectory()) {
    throw new FilesystemError('upload target is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  const rawName = String(filename || '').trim();
  const name = path.basename(rawName);
  if (!name || name === '.' || name === '..' || rawName.includes('/') || rawName.includes('\\')) {
    throw new FilesystemError('invalid upload file name', {
      status: 400,
      code: 'FS_INVALID_FILE_NAME',
    });
  }
  const target = path.resolve(directory, name);
  if (!isInside(directory, target)) {
    throw new FilesystemError('path is outside the target directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  assertPathAllowed(target);
  return { directory, target, name, root: directory, realRoot: directory };
}

// Workdir-relative download. Enforces the same size cap as the absolute path:
// a single file by its size, a directory by its uncompressed total.
async function prepareDownload(relativePath, workdir, { maxBytes } = {}) {
  const resolved = resolveExisting(relativePath, workdir);
  if (!resolved.stat.isFile() && !resolved.stat.isDirectory()) {
    throw new FilesystemError('only files and directories can be downloaded', {
      status: 400,
      code: 'FS_UNSUPPORTED_DOWNLOAD',
    });
  }
  const isDirectory = resolved.stat.isDirectory();
  if (isDirectory) assertTreeAllowed(resolved.target);
  const totalBytes = isDirectory
    ? await directorySize(resolved.target)
    : resolved.stat.size;
  if (typeof maxBytes === 'number' && maxBytes > 0 && totalBytes > maxBytes) {
    throw new FilesystemError('download exceeds the size limit', {
      status: 413,
      code: 'FS_DOWNLOAD_TOO_LARGE',
      meta: { totalBytes, maxBytes },
    });
  }
  const basename = path.basename(resolved.target) || 'workdir';
  return {
    ...resolved,
    filename: isDirectory ? `${basename}.zip` : basename,
    isDirectory,
    totalBytes,
    zipCwd: path.dirname(resolved.target),
    zipEntryName: basename,
  };
}

function resolveUploadTarget(relativePath, filename, workdir) {
  const resolved = resolveExisting(relativePath, workdir);
  if (!resolved.stat.isDirectory()) {
    throw new FilesystemError('upload target is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  const rawName = String(filename || '').trim();
  const name = path.basename(rawName);
  if (!name || name === '.' || name === '..' || rawName.includes('/') || rawName.includes('\\')) {
    throw new FilesystemError('invalid upload file name', {
      status: 400,
      code: 'FS_INVALID_FILE_NAME',
    });
  }
  const target = path.resolve(resolved.target, name);
  if (!isInside(resolved.root, target)) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  assertPathAllowed(target);
  return {
    root: resolved.root,
    realRoot: resolved.realRoot,
    directory: resolved.target,
    target,
    name,
  };
}

function uploadedEntry(root, target) {
  const stat = fs.lstatSync(target);
  return {
    name: path.basename(target),
    path: toApiPath(root, target),
    absolutePath: target,
    type: stat.isDirectory() ? 'directory' : stat.isFile() ? 'file' : 'other',
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
  };
}

module.exports = {
  FilesystemError,
  listAbsoluteDirectory,
  prepareDownload,
  prepareDownloadAbsolute,
  resolveUploadTarget,
  resolveAbsoluteUploadTarget,
  uploadedEntry,
};
