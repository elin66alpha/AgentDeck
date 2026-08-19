'use strict';

const assert = require('node:assert/strict');
const { afterEach, after, test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Every /api/* route is gated by this module, so its acceptance rules are the
// authentication boundary described in SECURITY.md.

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-tokens-test-'));
const tokensFile = path.join(tempDir, 'tokens.json');
process.env.RELAY_TOKENS_FILE = tokensFile;

const {
  TOKENS_FILE,
  createToken,
  deleteRevokedTokenById,
  hasConfiguredToken,
  isTokenAllowed,
  isTokenIdAllowed,
  listTokenSummaries,
  markTokenUsed,
  revokeToken,
  revokeTokenById,
  tokenRecordForToken,
} = require('../lib/tokens');

afterEach(() => {
  fs.rmSync(tokensFile, { force: true });
});

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
  delete process.env.RELAY_TOKENS_FILE;
});

function readFile() {
  return JSON.parse(fs.readFileSync(tokensFile, 'utf-8'));
}

test('RELAY_TOKENS_FILE redirects the store', () => {
  assert.equal(TOKENS_FILE, tokensFile);
});

// --- creation ----------------------------------------------------------------

test('no configured token until one is created', () => {
  assert.equal(hasConfiguredToken(), false);
  createToken({ label: 'Phone' });
  assert.equal(hasConfiguredToken(), true);
});

test('a created token has a random secret and an unrevoked record', () => {
  const first = createToken({ label: 'Phone' });
  const second = createToken({ label: 'Laptop' });

  assert.notEqual(first.token, second.token);
  // 32 random bytes, base64url encoded.
  assert.match(first.token, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(first.id, second.id);
  assert.equal(first.revoked, false);
  assert.ok(Date.parse(first.createdAt));
  assert.equal(readFile().length, 2);
});

test('a blank label falls back to a placeholder', () => {
  assert.equal(createToken({ label: '   ' }).label, 'Unnamed device');
  assert.equal(createToken({}).label, 'Unnamed device');
});

test('the token file is written owner-only', { skip: process.platform === 'win32' }, () => {
  createToken({ label: 'Phone' });
  assert.equal(fs.statSync(tokensFile).mode & 0o077, 0);
});

// --- acceptance --------------------------------------------------------------

test('only the exact token value is accepted', () => {
  const record = createToken({ label: 'Phone' });

  assert.equal(isTokenAllowed(record.token), true);
  // Surrounding whitespace from a header is tolerated.
  assert.equal(isTokenAllowed(`  ${record.token}  `), true);

  assert.equal(isTokenAllowed(''), false);
  assert.equal(isTokenAllowed(null), false);
  assert.equal(isTokenAllowed(undefined), false);
  // A prefix must not pass: the digest comparison is what makes a partial match
  // worthless rather than a step towards guessing the rest.
  assert.equal(isTokenAllowed(record.token.slice(0, -1)), false);
  assert.equal(isTokenAllowed(`${record.token}x`), false);
  assert.equal(isTokenAllowed(record.token.toUpperCase()), false);
});

test('candidates of any length are compared without throwing', () => {
  createToken({ label: 'Phone' });
  // timingSafeEqual needs equal-length buffers; hashing both sides first is what
  // keeps a short or overlong candidate from crashing the auth check.
  assert.equal(isTokenAllowed('x'), false);
  assert.equal(isTokenAllowed('y'.repeat(10000)), false);
});

test('each active token is accepted independently', () => {
  const first = createToken({ label: 'Phone' });
  const second = createToken({ label: 'Laptop' });
  assert.equal(isTokenAllowed(first.token), true);
  assert.equal(isTokenAllowed(second.token), true);
});

test('token ids are accepted only while the token is active', () => {
  const record = createToken({ label: 'Phone' });
  assert.equal(isTokenIdAllowed(record.id), true);
  assert.equal(isTokenIdAllowed('not-an-id'), false);
  assert.equal(isTokenIdAllowed(''), false);

  revokeTokenById(record.id);
  assert.equal(isTokenIdAllowed(record.id), false);
});

test('a record with an empty token value is never active', () => {
  fs.writeFileSync(
    tokensFile,
    JSON.stringify([{ id: 'blank', token: '   ', revoked: false }]),
  );
  assert.equal(hasConfiguredToken(), false);
  assert.equal(isTokenAllowed(''), false);
  assert.equal(isTokenAllowed('   '), false);
});

test('a malformed token file degrades to "no tokens" instead of accepting anything', () => {
  fs.writeFileSync(tokensFile, '{"not":"an array"}');
  assert.equal(hasConfiguredToken(), false);
  assert.equal(isTokenAllowed('anything'), false);
});

// --- revocation and deletion -------------------------------------------------

test('revoking by id stops the token from being accepted', () => {
  const record = createToken({ label: 'Phone' });
  const revoked = revokeTokenById(record.id);

  assert.equal(revoked.revoked, true);
  assert.ok(Date.parse(revoked.revokedAt));
  assert.equal(isTokenAllowed(record.token), false);
  assert.equal(hasConfiguredToken(), false);
});

test('revokeToken accepts either the id or the token value', () => {
  const byId = createToken({ label: 'Phone' });
  const byValue = createToken({ label: 'Laptop' });

  assert.equal(revokeToken(byId.id).revoked, true);
  assert.equal(revokeToken(byValue.token).revoked, true);
  assert.equal(revokeToken('unknown'), null);
  assert.equal(revokeToken(''), null);
  assert.equal(isTokenAllowed(byId.token), false);
  assert.equal(isTokenAllowed(byValue.token), false);
});

test('only a revoked record can be deleted', () => {
  const record = createToken({ label: 'Phone' });

  assert.equal(deleteRevokedTokenById(record.id), false);
  assert.equal(readFile().length, 1);
  assert.equal(deleteRevokedTokenById('unknown'), null);

  revokeTokenById(record.id);
  assert.equal(deleteRevokedTokenById(record.id).id, record.id);
  assert.equal(readFile().length, 0);
});

// --- summaries ---------------------------------------------------------------

test('summaries never expose the token value and mark the calling device', () => {
  const mine = createToken({ label: 'Phone' });
  createToken({ label: 'Laptop' });

  const summaries = listTokenSummaries({ currentToken: mine.token });
  assert.equal(summaries.length, 2);
  for (const summary of summaries) {
    assert.equal('token' in summary, false);
  }
  assert.deepEqual(
    summaries.map((summary) => [summary.label, summary.current]),
    [['Phone', true], ['Laptop', false]],
  );

  // Without a current token, nothing is marked as current.
  assert.equal(
    listTokenSummaries().every((summary) => summary.current === false),
    true,
  );
});

test('a revoked token still appears in summaries with its revocation time', () => {
  const record = createToken({ label: 'Phone' });
  revokeTokenById(record.id);

  const [summary] = listTokenSummaries();
  assert.equal(summary.revoked, true);
  assert.ok(Date.parse(summary.revokedAt));
});

test('tokenRecordForToken matches only an exact value', () => {
  const record = createToken({ label: 'Phone' });
  assert.equal(tokenRecordForToken(record.token).id, record.id);
  assert.equal(tokenRecordForToken(record.token.slice(0, -1)), null);
  assert.equal(tokenRecordForToken(''), null);
});

// --- last-use metadata -------------------------------------------------------

test('device metadata is recorded and trimmed', () => {
  const record = createToken({ label: 'Phone' });
  const used = markTokenUsed(record.token, {
    deviceId: '  device-1\n',
    deviceName: 'My   Phone ',
  });

  assert.equal(used.lastDeviceId, 'device-1');
  assert.equal(used.lastDeviceName, 'My Phone');
  assert.ok(Date.parse(used.lastUsedAt));
  assert.equal(readFile()[0].lastDeviceId, 'device-1');
});

test('overlong device metadata is capped', () => {
  const record = createToken({ label: 'Phone' });
  const used = markTokenUsed(record.token, {
    deviceId: 'i'.repeat(200),
    deviceName: 'n'.repeat(500),
  });
  assert.equal(used.lastDeviceId.length, 80);
  assert.equal(used.lastDeviceName.length, 160);
});

test('repeat use by the same device does not rewrite the file every request', () => {
  const record = createToken({ label: 'Phone' });
  const device = { deviceId: 'device-1', deviceName: 'Phone' };
  const start = new Date('2026-07-27T10:00:00.000Z');

  markTokenUsed(record.token, { ...device, now: start });
  // Well inside the write interval: the timestamp is left alone.
  markTokenUsed(record.token, {
    ...device,
    now: new Date(start.getTime() + 30 * 1000),
  });
  assert.equal(readFile()[0].lastUsedAt, start.toISOString());

  // Past the interval: the timestamp moves forward.
  const later = new Date(start.getTime() + 61 * 1000);
  markTokenUsed(record.token, { ...device, now: later });
  assert.equal(readFile()[0].lastUsedAt, later.toISOString());
});

test('a different device is recorded immediately', () => {
  const record = createToken({ label: 'Phone' });
  const start = new Date('2026-07-27T10:00:00.000Z');
  markTokenUsed(record.token, { deviceId: 'device-1', deviceName: 'Phone', now: start });

  const soon = new Date(start.getTime() + 1000);
  markTokenUsed(record.token, { deviceId: 'device-2', deviceName: 'Tablet', now: soon });
  assert.equal(readFile()[0].lastDeviceId, 'device-2');
  assert.equal(readFile()[0].lastUsedAt, soon.toISOString());
});

test('marking use of an unknown or revoked token changes nothing', () => {
  const record = createToken({ label: 'Phone' });
  assert.equal(markTokenUsed('not-a-token'), null);
  assert.equal(markTokenUsed(''), null);

  revokeTokenById(record.id);
  assert.equal(markTokenUsed(record.token, { deviceId: 'device-1' }), null);
  assert.equal(readFile()[0].lastDeviceId, undefined);
});
