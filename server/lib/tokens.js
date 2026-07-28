'use strict';

const crypto = require('crypto');
const path = require('path');

const { createJsonStore } = require('./json-store');

const TOKENS_FILE = process.env.RELAY_TOKENS_FILE
  ? path.resolve(process.env.RELAY_TOKENS_FILE)
  : path.join(__dirname, '..', 'tokens.json');

// Cached, atomic store. The `npm run credential` script writes tokens.json from
// a separate process; its write changes the file stamp, so this server's cached
// copy is refreshed on the next read instead of going stale.
const store = createJsonStore(TOKENS_FILE, {
  defaultValue: [],
  pretty: true,
  trailingNewline: true,
});

const TOKEN_USE_WRITE_INTERVAL_MS = 60 * 1000;

function readTokenRecords() {
  const decoded = store.load();
  return Array.isArray(decoded) ? decoded.filter((item) => item && item.token) : [];
}

function writeTokenRecords(records) {
  store.save(records);
}

function activeTokenRecords() {
  return readTokenRecords().filter(
    (record) => record && !record.revoked && String(record.token || '').trim(),
  );
}

function hasConfiguredToken() {
  return activeTokenRecords().length > 0;
}

// Compare a presented token against each active token in constant time, so a
// timing side channel can't reveal how many leading characters matched. Hashing
// both sides first keeps timingSafeEqual's equal-length requirement regardless
// of the candidate's length.
function tokenDigest(value) {
  return crypto.createHash('sha256').update(String(value)).digest();
}

function isTokenAllowed(token) {
  const clean = String(token || '').trim();
  if (!clean) return false;
  const candidate = tokenDigest(clean);
  let allowed = false;
  for (const record of activeTokenRecords()) {
    if (crypto.timingSafeEqual(candidate, tokenDigest(record.token))) {
      allowed = true;
    }
  }
  return allowed;
}

function isTokenIdAllowed(id) {
  const clean = String(id || '').trim();
  if (!clean) return false;
  return activeTokenRecords().some((record) => String(record.id || '') === clean);
}

function tokenRecordForToken(token) {
  const clean = String(token || '').trim();
  if (!clean) return null;
  return readTokenRecords().find((record) => clean === String(record.token)) || null;
}

function createToken({ label }) {
  const token = crypto.randomBytes(32).toString('base64url');
  const record = {
    id: crypto.randomUUID(),
    token,
    label: String(label || 'Unnamed device').trim() || 'Unnamed device',
    createdAt: new Date().toISOString(),
    revoked: false,
  };
  const records = readTokenRecords();
  records.push(record);
  writeTokenRecords(records);
  return record;
}

function cleanClientInfoValue(value, maxLength) {
  return String(value || '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, maxLength);
}

function markTokenUsed(token, { deviceId, deviceName, now = new Date() } = {}) {
  const clean = String(token || '').trim();
  if (!clean) return null;

  const records = readTokenRecords();
  const index = records.findIndex(
    (record) => record && !record.revoked && String(record.token || '') === clean,
  );
  if (index === -1) return null;

  const record = records[index];
  const nextDeviceId = cleanClientInfoValue(deviceId, 80);
  const nextDeviceName = cleanClientInfoValue(deviceName, 160);
  const nextTime = now instanceof Date ? now : new Date(now);
  const nextTimeMs = nextTime.getTime();
  const lastTimeMs = Date.parse(record.lastUsedAt || '');
  const sameDevice =
    String(record.lastDeviceId || '') === nextDeviceId &&
    String(record.lastDeviceName || '') === nextDeviceName;
  if (
    sameDevice &&
    Number.isFinite(lastTimeMs) &&
    Number.isFinite(nextTimeMs) &&
    nextTimeMs - lastTimeMs < TOKEN_USE_WRITE_INTERVAL_MS
  ) {
    return record;
  }

  records[index] = {
    ...record,
    lastUsedAt: nextTime.toISOString(),
    lastDeviceId: nextDeviceId,
    lastDeviceName: nextDeviceName,
  };
  writeTokenRecords(records);
  return records[index];
}

function listTokenSummaries({ currentToken } = {}) {
  const current = tokenRecordForToken(currentToken);
  return readTokenRecords().map((record) => ({
    id: record.id || '',
    label: record.label || '',
    createdAt: record.createdAt || '',
    revoked: !!record.revoked,
    revokedAt: record.revokedAt || '',
    lastUsedAt: record.lastUsedAt || '',
    lastDeviceId: record.lastDeviceId || '',
    lastDeviceName: record.lastDeviceName || '',
    current: !!(current && current.id && record.id === current.id),
  }));
}

function revokeTokenById(id) {
  const target = String(id || '').trim();
  if (!target) return null;

  const records = readTokenRecords();
  const index = records.findIndex((record) => record.id === target);
  if (index === -1) return null;

  records[index] = {
    ...records[index],
    revoked: true,
    revokedAt: new Date().toISOString(),
  };
  writeTokenRecords(records);
  return records[index];
}

function revokeToken(idOrToken) {
  const target = String(idOrToken || '').trim();
  if (!target) return null;

  const records = readTokenRecords();
  const index = records.findIndex(
    (record) => record.id === target || record.token === target,
  );
  if (index === -1) return null;

  records[index] = {
    ...records[index],
    revoked: true,
    revokedAt: new Date().toISOString(),
  };
  writeTokenRecords(records);
  return records[index];
}

function deleteRevokedTokenById(id) {
  const target = String(id || '').trim();
  if (!target) return null;

  const records = readTokenRecords();
  const index = records.findIndex((record) => record.id === target);
  if (index === -1) return null;
  if (!records[index].revoked) return false;

  const deleted = records[index];
  records.splice(index, 1);
  writeTokenRecords(records);
  return deleted;
}

module.exports = {
  TOKENS_FILE,
  createToken,
  deleteRevokedTokenById,
  hasConfiguredToken,
  isTokenIdAllowed,
  isTokenAllowed,
  listTokenSummaries,
  markTokenUsed,
  revokeToken,
  revokeTokenById,
  tokenRecordForToken,
};
