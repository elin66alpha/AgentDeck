'use strict';

// Shared storage + fan-out logic for the two offline notification channels,
// Web Push (push.js) and Firebase Cloud Messaging (fcm.js). Both keep a list of
// device records — each carrying the workdir and language it was registered
// under plus per-category opt-outs — and both deliver the same way: filter by
// workdir scope and category, send to all matching records in parallel, then
// prune the ones the provider reports as permanently gone. Only the record key
// (push endpoint vs FCM token), the wire send call, and the "this record is
// dead" test differ, so those are injected and everything else lives here.

const { createJsonStore } = require('./json-store');

const VALID_CATEGORIES = new Set(['quota', 'task']);

function normalizeCategories(categories) {
  const value =
    categories && typeof categories === 'object' && !Array.isArray(categories)
      ? categories
      : {};
  return {
    quota: value.quota !== false,
    task: value.task !== false,
  };
}

function normalizeRecord(record) {
  const value =
    record && typeof record === 'object' && !Array.isArray(record)
      ? record
      : {};
  return {
    ...value,
    categories: normalizeCategories(value.categories),
  };
}

function categoryAllowed(record, category) {
  if (!VALID_CATEGORIES.has(category)) return true;
  return normalizeCategories(record && record.categories)[category] !== false;
}

function pickLang(record, value, valueZh, fallback) {
  if (record.lang === 'zh' && valueZh) return valueZh;
  return value || valueZh || fallback;
}

// Build a store. `key` is the property that uniquely identifies a record
// (`endpoint` for push, `token` for FCM). `send(record, message)` performs the
// provider-specific delivery and throws on failure; `isGone(err)` returns true
// when the failure means the record should be dropped.
function createSubscriptionStore({ filePath, key, send, isGone }) {
  const store = createJsonStore(filePath, {
    defaultValue: [],
    pretty: true,
    trailingNewline: true,
  });

  function loadRecords() {
    const data = store.load();
    return Array.isArray(data) ? data.map(normalizeRecord) : [];
  }

  function idOf(record) {
    return record && typeof record[key] === 'string' ? record[key].trim() : '';
  }

  // Upsert keyed by the record id so re-registering the same device updates its
  // workdir/lang/categories instead of creating a duplicate row.
  function upsert(record) {
    const id = idOf(record);
    if (!id) return false;
    const list = loadRecords().filter((item) => idOf(item) !== id);
    list.push(record);
    store.save(list);
    return true;
  }

  function remove(rawId) {
    const id = String(rawId || '').trim();
    if (!id) return false;
    const list = loadRecords();
    const next = list.filter((item) => idOf(item) !== id);
    if (next.length === list.length) return false;
    store.save(next);
    return true;
  }

  async function notify({
    title,
    titleZh,
    message,
    messageZh,
    scopeWorkdir,
    category,
    tag,
  }) {
    const list = loadRecords();
    if (list.length === 0) return 0;
    const scoped =
      scopeWorkdir != null && scopeWorkdir !== ''
        ? list.filter((item) => item.workdir === scopeWorkdir)
        : list;
    const recipients = scoped.filter((item) => categoryAllowed(item, category));
    if (recipients.length === 0) return 0;

    const gone = [];
    let sent = 0;
    await Promise.all(
      recipients.map(async (record) => {
        if (!idOf(record)) return;
        const body = pickLang(record, message, messageZh, '');
        const notificationTitle = pickLang(record, title, titleZh, 'Relay');
        try {
          // The tag lets a client collapse this alert with its own copy of the
          // same event instead of showing both.
          await send(record, {
            title: notificationTitle,
            body,
            tag: tag || 'relay',
          });
          sent += 1;
        } catch (err) {
          if (isGone(err)) gone.push(idOf(record));
        }
      }),
    );

    if (gone.length > 0) {
      const next = loadRecords().filter((item) => !gone.includes(idOf(item)));
      store.save(next);
    }
    return sent;
  }

  return { loadRecords, upsert, remove, notify, normalizeCategories };
}

module.exports = { createSubscriptionStore, normalizeCategories };
