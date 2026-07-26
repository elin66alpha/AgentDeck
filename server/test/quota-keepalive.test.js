'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { planKeepalive } = require('../lib/quota-keepalive');

const NOW = Date.parse('2026-07-26T04:00:00.000Z');

test('waits until just after the running window lapses', () => {
  const plan = planKeepalive({
    usage: { resetsAt: '2026-07-26T06:00:00.000Z', stale: false },
    now: NOW,
    nextPrimeAllowedAt: 0,
  });
  assert.equal(plan.action, 'wait');
  assert.equal(plan.waitMs, 2 * 60 * 60 * 1000 + 30_000);
});

test('pings when the window is idle', () => {
  const plan = planKeepalive({
    usage: { resetsAt: null, stale: false },
    now: NOW,
    nextPrimeAllowedAt: 0,
  });
  assert.equal(plan.action, 'prime');
});

test('pings when the reported reset moment has already passed', () => {
  const plan = planKeepalive({
    usage: { resetsAt: '2026-07-26T03:59:00.000Z', stale: false },
    now: NOW,
    nextPrimeAllowedAt: 0,
  });
  assert.equal(plan.action, 'prime');
});

test('never pings on stale usage data', () => {
  const plan = planKeepalive({
    usage: { resetsAt: null, stale: true },
    now: NOW,
    nextPrimeAllowedAt: 0,
  });
  assert.equal(plan.action, 'wait');
});

test('respects the minimum interval between two pings', () => {
  const plan = planKeepalive({
    usage: { resetsAt: null, stale: false },
    now: NOW,
    nextPrimeAllowedAt: NOW + 300_000,
  });
  assert.equal(plan.action, 'wait');
  assert.equal(plan.waitMs, 300_000);
});

test('clamps an implausibly distant reset to the maximum sleep', () => {
  const plan = planKeepalive({
    usage: { resetsAt: '2027-01-01T00:00:00.000Z', stale: false },
    now: NOW,
    nextPrimeAllowedAt: 0,
  });
  assert.equal(plan.action, 'wait');
  assert.equal(plan.waitMs, 6 * 60 * 60 * 1000);
});
