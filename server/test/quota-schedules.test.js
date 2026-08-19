'use strict';

const assert = require('node:assert/strict');
const { afterEach, after, test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// A schedule holds one queued prompt per quota source until the next five-hour
// reset, so the invariants that matter are: one pending message per source and
// workspace, sane status transitions, and a bounded file.

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-schedules-test-'));
const schedulesFile = path.join(tempDir, 'quota-schedules.json');
process.env.RELAY_QUOTA_SCHEDULES_FILE = schedulesFile;

const {
  createQuotaSchedule,
  cancelQuotaSchedule,
  dueQuotaSchedulesForReset,
  listQuotaSchedules,
  markQuotaScheduleFailed,
  markQuotaScheduleRunning,
  markQuotaScheduleSent,
  reconcileRunningSchedules,
} = require('../lib/quota-schedules');

afterEach(() => {
  fs.rmSync(schedulesFile, { force: true });
});

after(() => {
  fs.rmSync(tempDir, { recursive: true, force: true });
  delete process.env.RELAY_QUOTA_SCHEDULES_FILE;
});

function makeSchedule(overrides = {}) {
  return createQuotaSchedule({
    sourceKey: 'claude',
    agentKey: 'claude',
    sessionId: 'main',
    sessionName: 'Main',
    workdir: '/work/app',
    prompt: 'continue the refactor',
    ...overrides,
  });
}

function caught(fn) {
  try {
    fn();
  } catch (err) {
    return err;
  }
  throw new assert.AssertionError({ message: 'expected the call to throw' });
}

// --- creation ----------------------------------------------------------------

test('a new schedule starts pending and keeps its scope', () => {
  const schedule = makeSchedule({ targetResetsAt: '2026-07-27T15:00:00.000Z' });

  assert.equal(schedule.status, 'pending');
  assert.equal(schedule.sourceKey, 'claude');
  assert.equal(schedule.workdir, '/work/app');
  assert.equal(schedule.prompt, 'continue the refactor');
  assert.equal(schedule.targetResetsAt, '2026-07-27T15:00:00.000Z');
  assert.ok(schedule.id);
  // The stored prompt is never exposed with the raw record's internals missing:
  // the public shape is what the API returns.
  assert.equal('error' in schedule, true);
});

test('an unparsable reset time degrades to "as soon as it resets"', () => {
  assert.equal(makeSchedule({ targetResetsAt: 'tomorrow-ish' }).targetResetsAt, null);
  assert.equal(makeSchedule({ workdir: '/other', targetResetsAt: '' }).targetResetsAt, null);
});

test('a prompt is required and bounded', () => {
  assert.equal(caught(() => makeSchedule({ prompt: '   ' })).code, 'PROMPT_REQUIRED');
  assert.equal(
    caught(() => makeSchedule({ prompt: 'x'.repeat(12001) })).code,
    'PROMPT_TOO_LONG',
  );
  assert.equal(makeSchedule({ prompt: 'x'.repeat(12000) }).prompt.length, 12000);
});

// --- one pending message per source and workspace ---------------------------

test('a second pending message for the same source and workspace is refused', () => {
  makeSchedule();
  const err = caught(() => makeSchedule({ prompt: 'something else' }));
  assert.equal(err.code, 'SCHEDULE_EXISTS');
  assert.equal(listQuotaSchedules().length, 1);
});

test('replaceExisting updates the pending message in place', () => {
  const first = makeSchedule();
  const replaced = makeSchedule({
    prompt: 'do this instead',
    sessionId: 'review',
    targetResetsAt: '2026-07-27T20:00:00.000Z',
    replaceExisting: true,
  });

  assert.equal(replaced.id, first.id);
  assert.equal(replaced.prompt, 'do this instead');
  assert.equal(replaced.sessionId, 'review');
  assert.equal(replaced.targetResetsAt, '2026-07-27T20:00:00.000Z');
  assert.equal(listQuotaSchedules().length, 1);
});

test('other sources and workspaces keep their own pending message', () => {
  makeSchedule();
  makeSchedule({ sourceKey: 'codex', agentKey: 'codex' });
  makeSchedule({ workdir: '/work/other' });
  assert.equal(listQuotaSchedules().length, 3);
});

test('a cancelled message frees the slot for a new one', () => {
  const first = makeSchedule();
  cancelQuotaSchedule(first.id);
  const second = makeSchedule({ prompt: 'a fresh plan' });
  assert.notEqual(second.id, first.id);
  assert.equal(second.status, 'pending');
});

// --- listing -----------------------------------------------------------------

test('listing can hide finished records and filter by workspace', () => {
  const finished = makeSchedule();
  cancelQuotaSchedule(finished.id);
  makeSchedule({ workdir: '/work/other' });

  assert.equal(listQuotaSchedules().length, 2);
  assert.equal(listQuotaSchedules({ includeFinished: false }).length, 1);
  assert.equal(listQuotaSchedules({ workdir: '/work/app' }).length, 1);
  assert.equal(listQuotaSchedules({ workdir: '/nowhere' }).length, 0);
});

// --- status transitions ------------------------------------------------------

test('a schedule runs, then reports sent', () => {
  const schedule = makeSchedule();

  const running = markQuotaScheduleRunning(schedule.id);
  assert.equal(running.status, 'running');
  assert.ok(Date.parse(running.startedAt));

  const sent = markQuotaScheduleSent(schedule.id);
  assert.equal(sent.status, 'sent');
  assert.ok(Date.parse(sent.sentAt));
  assert.equal(sent.error, null);
});

test('a failure keeps its reason', () => {
  const schedule = makeSchedule();
  const failed = markQuotaScheduleFailed(schedule.id, new Error('agent exited 1'));
  assert.equal(failed.status, 'failed');
  assert.match(failed.error, /agent exited 1/);

  assert.equal(markQuotaScheduleFailed('unknown-id', 'x'), null);
});

test('only a pending message can be cancelled', () => {
  const schedule = makeSchedule();
  markQuotaScheduleRunning(schedule.id);

  assert.equal(caught(() => cancelQuotaSchedule(schedule.id)).code, 'SCHEDULE_NOT_PENDING');
  assert.equal(cancelQuotaSchedule('unknown-id'), null);
});

test('schedules left running by a stopped server are failed on startup', () => {
  const running = makeSchedule();
  const pending = makeSchedule({ workdir: '/work/other' });
  markQuotaScheduleRunning(running.id);

  assert.equal(reconcileRunningSchedules(), 1);
  // A second pass has nothing left to do.
  assert.equal(reconcileRunningSchedules(), 0);

  const byId = new Map(listQuotaSchedules().map((item) => [item.id, item]));
  assert.equal(byId.get(running.id).status, 'failed');
  assert.match(byId.get(running.id).error, /server stopped/);
  assert.equal(byId.get(pending.id).status, 'pending');
});

// --- due detection -----------------------------------------------------------

test('due detection matches the source, the grace window, and pending only', () => {
  const now = new Date('2026-07-27T12:00:00.000Z');
  const soon = makeSchedule({
    targetResetsAt: new Date(now.getTime() + 5 * 60 * 1000).toISOString(),
  });
  const later = makeSchedule({
    workdir: '/work/later',
    targetResetsAt: new Date(now.getTime() + 60 * 60 * 1000).toISOString(),
  });
  const untargeted = makeSchedule({ workdir: '/work/untargeted' });
  const otherSource = makeSchedule({ sourceKey: 'codex', agentKey: 'codex' });

  const due = dueQuotaSchedulesForReset('claude', now).map((item) => item.id);
  // Inside the 10-minute grace window, and "next reset, whenever it is".
  assert.ok(due.includes(soon.id));
  assert.ok(due.includes(untargeted.id));
  assert.ok(!due.includes(later.id));
  assert.ok(!due.includes(otherSource.id));

  // Once it is running it is no longer due.
  markQuotaScheduleRunning(soon.id);
  assert.ok(!dueQuotaSchedulesForReset('claude', now).some((item) => item.id === soon.id));

  assert.deepEqual(dueQuotaSchedulesForReset('', now), []);
});

// --- file growth -------------------------------------------------------------

test('finished records are capped while live ones are always kept', () => {
  for (let i = 0; i < 60; i += 1) {
    const schedule = makeSchedule({ workdir: `/work/w${i}` });
    cancelQuotaSchedule(schedule.id);
  }
  const pending = makeSchedule({ workdir: '/work/live' });

  const onDisk = JSON.parse(fs.readFileSync(schedulesFile, 'utf-8'));
  assert.equal(onDisk.filter((item) => item.status === 'cancelled').length, 50);
  assert.equal(onDisk.filter((item) => item.id === pending.id).length, 1);
});
