'use strict';

const path = require('path');
const { randomUUID } = require('crypto');

const { createJsonStore } = require('./json-store');

const SCHEDULES_FILE = process.env.RELAY_QUOTA_SCHEDULES_FILE
  ? path.resolve(process.env.RELAY_QUOTA_SCHEDULES_FILE)
  : path.join(__dirname, '..', 'quota-schedules.json');
const MAX_PROMPT_LENGTH = 12000;
const RESET_GRACE_MS = 10 * 60 * 1000;
// Keep the file bounded: all live (pending/running) schedules are always kept,
// plus this many most-recent finished ones for history. Older finished records
// are dropped on the next write.
const MAX_FINISHED = 50;
const ACTIVE_STATUSES = ['pending', 'running'];

function isActive(schedule) {
  return ACTIVE_STATUSES.includes(schedule.status);
}

const store = createJsonStore(SCHEDULES_FILE, {
  defaultValue: [],
  pretty: true,
  trailingNewline: true,
});

function readQuotaSchedules() {
  const decoded = store.load();
  return Array.isArray(decoded) ? decoded : [];
}

// Never drop pending/running; cap the retained finished records so the file
// can't grow without bound.
function pruneSchedules(schedules) {
  const active = schedules.filter(isActive);
  const finished = schedules
    .filter((schedule) => !isActive(schedule))
    .sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')))
    .slice(0, MAX_FINISHED);
  return [...active, ...finished];
}

function writeQuotaSchedules(schedules) {
  store.save(pruneSchedules(schedules));
}

function publicSchedule(schedule) {
  return {
    id: schedule.id,
    sourceKey: schedule.sourceKey,
    agentKey: schedule.agentKey,
    sessionId: schedule.sessionId,
    sessionName: schedule.sessionName || '',
    workdir: schedule.workdir,
    prompt: schedule.prompt,
    targetResetsAt: schedule.targetResetsAt || null,
    status: schedule.status,
    createdAt: schedule.createdAt,
    updatedAt: schedule.updatedAt,
    startedAt: schedule.startedAt || null,
    sentAt: schedule.sentAt || null,
    error: schedule.error || null,
  };
}

function listQuotaSchedules({ includeFinished = true, workdir } = {}) {
  const schedules = readQuotaSchedules();
  const filtered = includeFinished ? schedules : schedules.filter(isActive);
  return filtered
    .filter((item) => !workdir || item.workdir === workdir)
    .slice()
    .sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')))
    .slice(0, 50)
    .map(publicSchedule);
}

function cleanPrompt(value) {
  const prompt = String(value || '').trim();
  if (!prompt) {
    const err = new Error('prompt is required');
    err.code = 'PROMPT_REQUIRED';
    throw err;
  }
  if (prompt.length > MAX_PROMPT_LENGTH) {
    const err = new Error(`prompt exceeds ${MAX_PROMPT_LENGTH} characters`);
    err.code = 'PROMPT_TOO_LONG';
    throw err;
  }
  return prompt;
}

function normalizeResetTime(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;
  const parsed = new Date(raw);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function createQuotaSchedule({
  sourceKey,
  agentKey,
  sessionId,
  sessionName,
  workdir,
  prompt,
  targetResetsAt,
  replaceExisting = false,
}) {
  const now = new Date().toISOString();
  const schedule = {
    id: randomUUID(),
    sourceKey: String(sourceKey || '').trim(),
    agentKey: String(agentKey || '').trim(),
    sessionId: String(sessionId || '').trim(),
    sessionName: String(sessionName || '').trim(),
    workdir: String(workdir || '').trim(),
    prompt: cleanPrompt(prompt),
    targetResetsAt: normalizeResetTime(targetResetsAt),
    status: 'pending',
    createdAt: now,
    updatedAt: now,
  };
  const schedules = readQuotaSchedules();
  // One pending message per quota source: a 5-hour reset is a single host-wide
  // event. Scope it by workdir so all devices in the same workspace see and
  // replace the same scheduled message, while unrelated workspaces don't leak
  // into each other's schedule UI.
  const existingIndex = schedules.findIndex(
    (item) =>
      item.status === 'pending' &&
      item.sourceKey === schedule.sourceKey &&
      item.workdir === schedule.workdir,
  );
  if (existingIndex !== -1 && !replaceExisting) {
    const err = new Error(
      `a pending ${schedule.sourceKey} scheduled message already exists`,
    );
    err.code = 'SCHEDULE_EXISTS';
    throw err;
  }
  if (existingIndex !== -1) {
    schedules[existingIndex] = {
      ...schedules[existingIndex],
      agentKey: schedule.agentKey,
      sessionId: schedule.sessionId,
      sessionName: schedule.sessionName,
      prompt: schedule.prompt,
      targetResetsAt: schedule.targetResetsAt,
      error: null,
      updatedAt: now,
    };
    writeQuotaSchedules(schedules);
    return publicSchedule(schedules[existingIndex]);
  }
  schedules.push(schedule);
  writeQuotaSchedules(schedules);
  return publicSchedule(schedule);
}

// Schedules left as 'running' when the process stopped can never be retried or
// reported (the due-scan only looks at 'pending'); fail them on startup so they
// don't sit invisible forever.
function reconcileRunningSchedules() {
  const schedules = readQuotaSchedules();
  const now = new Date().toISOString();
  let changed = 0;
  for (const schedule of schedules) {
    if (schedule.status === 'running') {
      schedule.status = 'failed';
      schedule.error = 'server stopped while the scheduled message was running';
      schedule.updatedAt = now;
      changed += 1;
    }
  }
  if (changed) writeQuotaSchedules(schedules);
  return changed;
}

function updateSchedule(id, updater) {
  const schedules = readQuotaSchedules();
  const index = schedules.findIndex((item) => item.id === id);
  if (index === -1) return null;
  schedules[index] = {
    ...schedules[index],
    ...updater(schedules[index]),
    updatedAt: new Date().toISOString(),
  };
  writeQuotaSchedules(schedules);
  return publicSchedule(schedules[index]);
}

function cancelQuotaSchedule(id) {
  return updateSchedule(id, (schedule) => {
    if (schedule.status !== 'pending') {
      const err = new Error('only pending scheduled messages can be cancelled');
      err.code = 'SCHEDULE_NOT_PENDING';
      throw err;
    }
    return { status: 'cancelled' };
  });
}

function markQuotaScheduleRunning(id) {
  return updateSchedule(id, () => ({
    status: 'running',
    startedAt: new Date().toISOString(),
    error: null,
  }));
}

function markQuotaScheduleSent(id) {
  return updateSchedule(id, () => ({
    status: 'sent',
    sentAt: new Date().toISOString(),
    error: null,
  }));
}

function markQuotaScheduleFailed(id, error) {
  return updateSchedule(id, () => ({
    status: 'failed',
    error: String(error || 'scheduled message failed'),
  }));
}

function dueQuotaSchedulesForReset(sourceKey, now = new Date()) {
  const source = String(sourceKey || '').trim();
  const upperBound = now.getTime() + RESET_GRACE_MS;
  return readQuotaSchedules()
    .filter((schedule) => {
      if (schedule.status !== 'pending') return false;
      if (schedule.sourceKey !== source) return false;
      if (!schedule.targetResetsAt) return true;
      const target = new Date(schedule.targetResetsAt).getTime();
      return !Number.isNaN(target) && target <= upperBound;
    })
    .map(publicSchedule);
}

module.exports = {
  createQuotaSchedule,
  cancelQuotaSchedule,
  dueQuotaSchedulesForReset,
  listQuotaSchedules,
  markQuotaScheduleFailed,
  markQuotaScheduleRunning,
  markQuotaScheduleSent,
  reconcileRunningSchedules,
};
