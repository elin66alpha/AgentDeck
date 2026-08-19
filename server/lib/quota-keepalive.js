'use strict';

const { getClaudeUsage, invalidateUsageCache, primeClaudeSession } = require('./usage');

// Restart the window a little after it lapses so the usage API has already
// rolled over when we ping.
const GRACE_MS = parseInt(process.env.CLAUDE_KEEPALIVE_GRACE_MS || '30000', 10);
// How long to wait before re-reading usage to confirm a ping started a window.
const VERIFY_MS = parseInt(process.env.CLAUDE_KEEPALIVE_VERIFY_MS || '30000', 10);
// Floor between two pings. Guards against hammering the API if a ping somehow
// does not open a window (wrong account, plan without a five-hour window).
const MIN_PRIME_INTERVAL_MS = parseInt(
  process.env.CLAUDE_KEEPALIVE_MIN_INTERVAL_MS || '600000',
  10,
);
const ERROR_RETRY_MS = parseInt(
  process.env.CLAUDE_KEEPALIVE_ERROR_RETRY_MS || '900000',
  10,
);
const MIN_WAIT_MS = 15_000;
const MAX_WAIT_MS = 6 * 60 * 60 * 1000;

function clampWait(ms) {
  if (!Number.isFinite(ms)) return ERROR_RETRY_MS;
  return Math.min(MAX_WAIT_MS, Math.max(MIN_WAIT_MS, Math.round(ms)));
}

// Pure scheduling decision, split out so the loop stays trivially testable.
// `usage` is the normalized { resetsAt, stale } view of Claude's five-hour block.
function planKeepalive({ usage, now, nextPrimeAllowedAt }) {
  const resetsAt = usage && usage.resetsAt ? Date.parse(usage.resetsAt) : NaN;
  if (Number.isFinite(resetsAt) && resetsAt > now) {
    // Window is running: sleep until just after it lapses.
    return { action: 'wait', waitMs: clampWait(resetsAt - now + GRACE_MS) };
  }
  if (usage && usage.stale) {
    // A cached value whose source is unreachable says nothing about the live
    // window; re-read rather than send a turn the user did not ask for.
    return { action: 'wait', waitMs: clampWait(VERIFY_MS) };
  }
  if (now < nextPrimeAllowedAt) {
    return { action: 'wait', waitMs: clampWait(nextPrimeAllowedAt - now) };
  }
  return { action: 'prime', waitMs: clampWait(VERIFY_MS) };
}

function readClaudeFiveHour(report) {
  const block = (report && report.data && report.data.five_hour) || {};
  return { resetsAt: block.resets_at || null, stale: !!(report && report.stale) };
}

// Keeps Claude Code's five-hour window cycling so the usage screen never has to
// report "unknown". Codex learns its reset time from a separate minimal request;
// neither provider request should be described as free of quota impact.
function startClaudeQuotaKeepalive({
  readUsage = async () => readClaudeFiveHour(await getClaudeUsage()),
  prime = primeClaudeSession,
  invalidate = () => invalidateUsageCache('claude'),
} = {}) {
  let timer = null;
  let stopped = false;
  let nextPrimeAllowedAt = 0;

  async function tick() {
    let waitMs = ERROR_RETRY_MS;
    try {
      const usage = await readUsage();
      const plan = planKeepalive({
        usage,
        now: Date.now(),
        nextPrimeAllowedAt,
      });
      waitMs = plan.waitMs;
      if (plan.action === 'prime') {
        nextPrimeAllowedAt = Date.now() + MIN_PRIME_INTERVAL_MS;
        const result = await prime();
        invalidate();
        console.log(
          `[quota:claude] keepalive ping sent (HTTP ${result && result.status}); ` +
            'five-hour window restarted',
        );
      }
    } catch (err) {
      console.warn(`[quota:claude] keepalive failed: ${err.message}`);
      waitMs = ERROR_RETRY_MS;
    }
    if (stopped) return;
    timer = setTimeout(tick, clampWait(waitMs));
    if (timer.unref) timer.unref();
  }

  console.log(
    '[quota:claude] five-hour keepalive started; a minimal request restarts the ' +
      'window whenever it lapses',
  );
  tick();

  return {
    stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
      timer = null;
    },
  };
}

module.exports = { startClaudeQuotaKeepalive, planKeepalive };
