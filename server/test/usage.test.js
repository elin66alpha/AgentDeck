'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { markExpiredQuotas } = require('../lib/usage');

const NOW = Date.parse('2026-06-19T12:00:00Z');

test('markExpiredQuotas leaves fresh (non-stale) data untouched', () => {
  const quotas = [
    { key: 'five_hour', resetsAt: '2026-06-19T08:00:00Z', expired: false },
  ];
  const out = markExpiredQuotas(quotas, false, NOW);
  assert.equal(out, quotas);
  assert.equal(out[0].expired, false);
});

test('markExpiredQuotas flags stale buckets whose reset has passed', () => {
  const quotas = [
    { key: 'five_hour', resetsAt: '2026-06-19T08:00:00Z', expired: false },
    { key: 'seven_day', resetsAt: '2026-06-24T00:00:00Z', expired: false },
  ];
  const out = markExpiredQuotas(quotas, true, NOW);
  assert.equal(out[0].expired, true); // 08:00 < 12:00 → window already reset
  assert.equal(out[1].expired, false); // future reset → still meaningful
});

test('markExpiredQuotas treats the exact reset moment as expired', () => {
  const quotas = [
    { key: 'five_hour', resetsAt: '2026-06-19T12:00:00Z', expired: false },
  ];
  assert.equal(markExpiredQuotas(quotas, true, NOW)[0].expired, true);
});

test('markExpiredQuotas ignores buckets without a reset time', () => {
  const quotas = [{ key: 'five_hour', resetsAt: null, expired: false }];
  const out = markExpiredQuotas(quotas, true, NOW);
  assert.equal(out[0].expired, false);
});
