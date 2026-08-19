'use strict';

// Pure helpers for the group-chat orchestrator (see docs/handbook.md, "Swarms").
// These turn the canonical group transcript into per-agent prompt material:
//
//   * who authored a transcript message (attribution),
//   * which agents a human message summons (@mention parsing),
//   * the delta a given agent has not seen since it last spoke ("plan B"),
//   * a speaker-labeled prompt for that delta, bounded to the prompt size cap.
//
// Keeping them pure (no I/O, no agent runners) makes the labeling — the part the
// design calls out as what keeps attribution and tone correct — directly testable.

const HUMAN_AUTHOR = 'human';

// A group prompt shares the ordinary chat byte budget. The default leaves
// headroom below the 100KB request cap.
const DEFAULT_MAX_PROMPT_BYTES = 96 * 1024;

function slug(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

// The author of a transcript message: explicit metadata.author wins (that is how
// the orchestrator records it), otherwise fall back to role/agent so a message
// written before attribution metadata still resolves sensibly.
function authorOf(message) {
  const metadata = message && message.metadata;
  if (metadata && typeof metadata.author === 'string' && metadata.author) {
    return metadata.author;
  }
  if (message && message.role === 'user') return HUMAN_AUTHOR;
  return (message && message.agent) || '';
}

// Ordered, de-duplicated list of member agent keys the human summoned in this
// message. Tokens match a member by its agent key or by the slug of its display
// label, so both `@claude` and `@Claude Code` resolve. Only current members can
// be summoned; broad aliases such as `@all` are intentionally ignored.
function parseMentions(prompt, members, labelFor) {
  const text = String(prompt || '');
  const list = Array.isArray(members) ? members : [];
  const order = [];
  const seen = new Set();
  const add = (key) => {
    if (key && !seen.has(key)) {
      seen.add(key);
      order.push(key);
    }
  };
  const re = /(?:^|[^\w@])@([A-Za-z0-9:_-]+)/g;
  let match;
  while ((match = re.exec(text)) !== null) {
    const token = match[1].toLowerCase();
    const target = list.find(
      (member) =>
        member.toLowerCase() === token ||
        slug(typeof labelFor === 'function' ? labelFor(member) : member) === slug(token),
    );
    if (target) add(target);
  }
  return order;
}

// The transcript tail an agent has not yet seen: everything after its own last
// message. An agent that has never spoken sees the whole transcript so far.
function deltaSince(messages, agentKey) {
  const list = Array.isArray(messages) ? messages : [];
  let lastIndex = -1;
  for (let i = list.length - 1; i >= 0; i -= 1) {
    if (authorOf(list[i]) === agentKey) {
      lastIndex = i;
      break;
    }
  }
  return list.slice(lastIndex + 1);
}

function speakerLabel(message, labelFor) {
  const author = authorOf(message);
  if (author === HUMAN_AUTHOR) return 'Human';
  if (typeof labelFor === 'function') return labelFor(author) || author;
  return author;
}

function lineFor(message, labelFor) {
  const content = typeof (message && message.content) === 'string'
    ? message.content.trim()
    : '';
  if (!content) return '';
  return `${speakerLabel(message, labelFor)}: ${content}`;
}

// Build the prompt handed to the agent taking the floor: a header that states it
// is in a group and it is now its turn, the `roster` of members it may summon
// (already excluding itself; empty when agent-to-agent summoning is off), an
// optional `persona` line carrying the user's per-member work instructions, then
// each delta message labeled with its speaker. Bounded to maxBytes by keeping the
// most recent messages and noting any omission, so a long silence cannot produce
// a prompt that exceeds the request budget.
function buildGroupPrompt({
  selfLabel,
  persona,
  delta,
  labelFor,
  roster,
  maxBytes = DEFAULT_MAX_PROMPT_BYTES,
}) {
  const name = String(selfLabel || 'this agent');
  const role = typeof persona === 'string' ? persona.trim() : '';
  // Summoning only happens if the agent knows it can, and knows the exact token
  // that resolves. Each entry is `Label (@key)`: the key always parses, while a
  // nickname only does when it is a single word.
  const others = (Array.isArray(roster) ? roster : [])
    .filter((member) => member && member.key)
    .map((member) => `${member.label || member.key} (@${member.key})`);
  const rosterLine = others.length
    ? `\n\nOther members of this swarm: ${others.join(', ')}. ` +
      'Mentioning one of them by that @name hands them the floor once you ' +
      'finish, and they will see this exchange. Only do it when you actually ' +
      'need them; say nothing of the sort to end the exchange.'
    : '';
  const header =
    `You are "${name}" in a group chat with a human and possibly other AI agents. ` +
    'Each line below is prefixed with its speaker. Reply only as yourself, ' +
    'addressing the conversation; it is now your turn to respond.' +
    rosterLine +
    (role ? `\n\nYour role in this swarm: ${role}` : '');
  const footer = `(It is now your turn, ${name}.)`;
  const omitted = '[earlier messages omitted]';

  const lines = [];
  for (const message of Array.isArray(delta) ? delta : []) {
    const line = lineFor(message, labelFor);
    if (line) lines.push(line);
  }

  const overhead =
    Buffer.byteLength(header, 'utf8') +
    Buffer.byteLength(footer, 'utf8') +
    Buffer.byteLength(omitted, 'utf8') +
    16;
  const budget = Math.max(1024, maxBytes - overhead);

  const kept = [];
  let total = 0;
  let truncated = false;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const size = Buffer.byteLength(lines[i], 'utf8') + 2;
    if (kept.length > 0 && total + size > budget) {
      truncated = true;
      break;
    }
    kept.unshift(lines[i]);
    total += size;
  }
  if (truncated) kept.unshift(omitted);

  const body = kept.length > 0 ? kept.join('\n\n') : '(no new messages)';
  let prompt = `${header}\n\n${body}\n\n${footer}`;
  // Defence in depth: a single oversized message can still blow the budget;
  // hard-cap the generated protocol payload before handing it to a runner.
  if (Buffer.byteLength(prompt, 'utf8') > maxBytes) {
    prompt = Buffer.from(prompt, 'utf8').subarray(0, maxBytes).toString('utf8');
  }
  return prompt;
}

module.exports = {
  HUMAN_AUTHOR,
  DEFAULT_MAX_PROMPT_BYTES,
  authorOf,
  parseMentions,
  deltaSince,
  buildGroupPrompt,
};
