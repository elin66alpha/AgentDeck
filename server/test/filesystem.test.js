'use strict';

const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// The file API is the boundary SECURITY.md promises: a leaked device token must
// not be able to read tokens/CLI credentials through it, and RELAY_FS_ROOTS must
// actually narrow the reachable filesystem.

const modulePath = require.resolve('../lib/filesystem');
// realpath so comparisons hold on hosts where the temp dir is itself a link
// (macOS /var -> /private/var).
const scratchRoot = fs.realpathSync(
  fs.mkdtempSync(path.join(os.tmpdir(), 'relay-fs-test-')),
);

after(() => fs.rmSync(scratchRoot, { recursive: true, force: true }));

// filesystem.js reads RELAY_FS_ROOTS and the home directory once, at load time,
// so each policy variant needs its own freshly loaded copy of the module.
function loadFilesystem({ roots, home } = {}) {
  const prev = {
    roots: process.env.RELAY_FS_ROOTS,
    home: process.env.HOME,
    userProfile: process.env.USERPROFILE,
  };
  const restore = (key, value) => {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  };
  if (roots === undefined) delete process.env.RELAY_FS_ROOTS;
  else process.env.RELAY_FS_ROOTS = roots;
  if (home !== undefined) {
    process.env.HOME = home;
    process.env.USERPROFILE = home;
  }
  delete require.cache[modulePath];
  try {
    return require('../lib/filesystem');
  } finally {
    delete require.cache[modulePath];
    restore('RELAY_FS_ROOTS', prev.roots);
    restore('HOME', prev.home);
    restore('USERPROFILE', prev.userProfile);
  }
}

let caseCounter = 0;
function scratchCase() {
  caseCounter += 1;
  const dir = path.join(scratchRoot, `case-${caseCounter}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// A stand-in home directory holding the credential files the denylist names.
function fakeHome() {
  const home = path.join(scratchCase(), 'home');
  fs.mkdirSync(path.join(home, '.ssh'), { recursive: true });
  fs.writeFileSync(path.join(home, '.ssh', 'id_ed25519'), 'private-key');
  fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(home, '.claude', '.credentials.json'), '{}');
  fs.mkdirSync(path.join(home, '.codex'), { recursive: true });
  fs.writeFileSync(path.join(home, '.codex', 'auth.json'), '{}');
  return home;
}

// Run fn, asserting it rejects, and return the thrown error.
async function rejects(fn) {
  try {
    await fn();
  } catch (err) {
    return err;
  }
  throw new assert.AssertionError({ message: 'expected the call to reject' });
}

// --- denylist: listing, download, and upload alike ---------------------------

test('listing a denied directory is refused', async () => {
  const home = fakeHome();
  const { listAbsoluteDirectory } = loadFilesystem({ home });
  const err = await rejects(() => listAbsoluteDirectory(path.join(home, '.ssh')));
  assert.equal(err.code, 'FS_PATH_RESTRICTED');
  assert.equal(err.status, 403);
});

test('downloading a denied CLI credential file is refused', async () => {
  const home = fakeHome();
  const { prepareDownloadAbsolute } = loadFilesystem({ home });
  for (const denied of [
    path.join(home, '.claude', '.credentials.json'),
    path.join(home, '.codex', 'auth.json'),
    path.join(home, '.ssh', 'id_ed25519'),
  ]) {
    const err = await rejects(() => prepareDownloadAbsolute(denied));
    assert.equal(err.code, 'FS_PATH_RESTRICTED', denied);
  }
});

test('the atomic-write temp file beside a denied path is refused too', async () => {
  const home = fakeHome();
  const tmpTwin = path.join(home, '.codex', 'auth.json.tmp');
  fs.writeFileSync(tmpTwin, '{}');
  const { prepareDownloadAbsolute } = loadFilesystem({ home });
  const err = await rejects(() => prepareDownloadAbsolute(tmpTwin));
  assert.equal(err.code, 'FS_PATH_RESTRICTED');
});

test('uploading into a denied directory is refused', () => {
  const home = fakeHome();
  const { resolveAbsoluteUploadTarget } = loadFilesystem({ home });
  assert.throws(
    () => resolveAbsoluteUploadTarget(path.join(home, '.ssh'), 'authorized_keys'),
    (err) => err.code === 'FS_PATH_RESTRICTED',
  );
});

test('a directory download containing a denied path is refused', async () => {
  const home = fakeHome();
  const { prepareDownloadAbsolute } = loadFilesystem({ home });
  // ~/.codex itself is not on the denylist, but zipping it would carry
  // auth.json out with it.
  const err = await rejects(() => prepareDownloadAbsolute(path.join(home, '.codex')));
  assert.equal(err.code, 'FS_PATH_RESTRICTED');
});

test('ordinary paths outside the denylist stay reachable', async () => {
  const home = fakeHome();
  const project = path.join(home, 'project');
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(project, 'notes.md'), 'hello');
  const { listAbsoluteDirectory, prepareDownloadAbsolute } = loadFilesystem({ home });

  const listing = await listAbsoluteDirectory(project);
  assert.deepEqual(
    listing.entries.map((entry) => entry.name),
    ['notes.md'],
  );

  const download = await prepareDownloadAbsolute(path.join(project, 'notes.md'));
  assert.equal(download.isDirectory, false);
  assert.equal(download.filename, 'notes.md');
  assert.equal(download.totalBytes, 5);
});

// --- RELAY_FS_ROOTS ----------------------------------------------------------

test('RELAY_FS_ROOTS refuses paths outside the configured roots', async () => {
  const base = scratchCase();
  const allowed = path.join(base, 'allowed');
  const outside = path.join(base, 'outside');
  fs.mkdirSync(allowed);
  fs.mkdirSync(outside);
  const { listAbsoluteDirectory } = loadFilesystem({ roots: allowed });

  const listed = await listAbsoluteDirectory(allowed);
  assert.equal(listed.path, allowed);

  const err = await rejects(() => listAbsoluteDirectory(outside));
  assert.equal(err.code, 'FS_PATH_OUTSIDE_ROOTS');
  assert.equal(err.status, 403);
});

test('RELAY_FS_ROOTS accepts a comma-separated list and ignores blank entries', async () => {
  const base = scratchCase();
  const first = path.join(base, 'first');
  const second = path.join(base, 'second');
  fs.mkdirSync(first);
  fs.mkdirSync(path.join(second, 'nested'), { recursive: true });
  const { listAbsoluteDirectory } = loadFilesystem({
    roots: ` ${first} , , ${second} `,
  });

  assert.equal((await listAbsoluteDirectory(first)).path, first);
  // Nested paths under a root are inside it.
  assert.equal(
    (await listAbsoluteDirectory(path.join(second, 'nested'))).path,
    path.join(second, 'nested'),
  );
  assert.equal(
    (await rejects(() => listAbsoluteDirectory(base))).code,
    'FS_PATH_OUTSIDE_ROOTS',
  );
});

test('a sibling whose name merely starts with a root name is outside it', async () => {
  const base = scratchCase();
  const allowed = path.join(base, 'data');
  const lookalike = path.join(base, 'data-backup');
  fs.mkdirSync(allowed);
  fs.mkdirSync(lookalike);
  const { listAbsoluteDirectory } = loadFilesystem({ roots: allowed });
  assert.equal(
    (await rejects(() => listAbsoluteDirectory(lookalike))).code,
    'FS_PATH_OUTSIDE_ROOTS',
  );
});

// --- workdir-relative confinement -------------------------------------------

test('relative download paths cannot climb out of the workdir', async () => {
  const base = scratchCase();
  const workdir = path.join(base, 'work');
  fs.mkdirSync(workdir);
  fs.writeFileSync(path.join(base, 'secret.txt'), 'nope');
  const { prepareDownload } = loadFilesystem();

  const err = await rejects(() => prepareDownload('../secret.txt', workdir));
  assert.equal(err.code, 'FS_PATH_OUTSIDE_WORKDIR');
  assert.equal(err.status, 403);
});

test('the relative browser refuses an absolute path, and the absolute one refuses a relative path', async () => {
  const workdir = scratchCase();
  const { prepareDownload, listAbsoluteDirectory } = loadFilesystem();

  assert.equal(
    (await rejects(() => prepareDownload(workdir, workdir))).code,
    'FS_PATH_MUST_BE_RELATIVE',
  );
  assert.equal(
    (await rejects(() => listAbsoluteDirectory('relative/dir'))).code,
    'FS_PATH_MUST_BE_ABSOLUTE',
  );
});

test('a missing path reports not-found rather than leaking a policy decision', async () => {
  const { listAbsoluteDirectory, prepareDownloadAbsolute } = loadFilesystem();
  const missing = path.join(scratchCase(), 'nope');
  assert.equal(
    (await rejects(() => listAbsoluteDirectory(missing))).status,
    404,
  );
  assert.equal(
    (await rejects(() => prepareDownloadAbsolute(missing))).status,
    404,
  );
});

// --- upload naming -----------------------------------------------------------

test('upload file names are reduced to a bare basename', () => {
  const workdir = scratchCase();
  const { resolveAbsoluteUploadTarget } = loadFilesystem();

  for (const bad of ['../escape.txt', 'nested/file.txt', 'nested\\file.txt', '..', '.', '']) {
    assert.throws(
      () => resolveAbsoluteUploadTarget(workdir, bad),
      (err) => err.code === 'FS_INVALID_FILE_NAME',
      `expected ${JSON.stringify(bad)} to be refused`,
    );
  }

  const ok = resolveAbsoluteUploadTarget(workdir, 'report.pdf');
  assert.equal(ok.target, path.join(workdir, 'report.pdf'));
  assert.equal(ok.name, 'report.pdf');
});

test('uploading requires an existing absolute directory', () => {
  const workdir = scratchCase();
  const file = path.join(workdir, 'a.txt');
  fs.writeFileSync(file, 'a');
  const { resolveAbsoluteUploadTarget } = loadFilesystem();

  assert.throws(
    () => resolveAbsoluteUploadTarget('relative', 'a.txt'),
    (err) => err.code === 'FS_PATH_MUST_BE_ABSOLUTE',
  );
  assert.throws(
    () => resolveAbsoluteUploadTarget(file, 'a.txt'),
    (err) => err.code === 'FS_PATH_NOT_DIRECTORY',
  );
});

// --- size caps ---------------------------------------------------------------

test('an oversized file download is refused before any bytes are streamed', async () => {
  const dir = scratchCase();
  const file = path.join(dir, 'big.bin');
  fs.writeFileSync(file, Buffer.alloc(2048));
  const { prepareDownloadAbsolute } = loadFilesystem();

  const err = await rejects(() => prepareDownloadAbsolute(file, { maxBytes: 1024 }));
  assert.equal(err.code, 'FS_DOWNLOAD_TOO_LARGE');
  assert.equal(err.status, 413);

  // Exactly at the cap is still allowed.
  const ok = await prepareDownloadAbsolute(file, { maxBytes: 2048 });
  assert.equal(ok.totalBytes, 2048);
});

test('a directory download is measured by its uncompressed total', async () => {
  const dir = path.join(scratchCase(), 'tree');
  fs.mkdirSync(path.join(dir, 'nested'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'a.bin'), Buffer.alloc(600));
  fs.writeFileSync(path.join(dir, 'nested', 'b.bin'), Buffer.alloc(600));
  const { prepareDownloadAbsolute } = loadFilesystem();

  const err = await rejects(() => prepareDownloadAbsolute(dir, { maxBytes: 1000 }));
  assert.equal(err.code, 'FS_DOWNLOAD_TOO_LARGE');

  const ok = await prepareDownloadAbsolute(dir, { maxBytes: 4096 });
  assert.equal(ok.isDirectory, true);
  assert.equal(ok.totalBytes, 1200);
  assert.equal(ok.filename, 'tree.zip');
  assert.equal(ok.zipEntryName, 'tree');
});

// --- listing shape -----------------------------------------------------------

test('hidden entries are listed only when asked for', async () => {
  const dir = scratchCase();
  fs.writeFileSync(path.join(dir, 'visible.txt'), 'a');
  fs.writeFileSync(path.join(dir, '.hidden'), 'b');
  const { listAbsoluteDirectory } = loadFilesystem();

  const plain = await listAbsoluteDirectory(dir);
  assert.deepEqual(plain.entries.map((entry) => entry.name), ['visible.txt']);

  const hidden = await listAbsoluteDirectory(dir, { showHidden: true });
  assert.deepEqual(
    hidden.entries.map((entry) => entry.name).sort(),
    ['.hidden', 'visible.txt'],
  );
});

test('directories sort ahead of files and carry absolute paths', async () => {
  const dir = scratchCase();
  fs.mkdirSync(path.join(dir, 'zeta'));
  fs.writeFileSync(path.join(dir, 'alpha.txt'), 'a');
  const { listAbsoluteDirectory } = loadFilesystem();

  const listing = await listAbsoluteDirectory(dir);
  assert.deepEqual(
    listing.entries.map((entry) => [entry.name, entry.type]),
    [['zeta', 'directory'], ['alpha.txt', 'file']],
  );
  assert.equal(listing.entries[0].absolutePath, path.join(dir, 'zeta'));
  assert.equal(listing.parentPath, path.dirname(dir));
});
