import { test } from 'node:test';
import assert from 'node:assert/strict';
import { contactFields, createContact, e164, findContactByExternalId, listContactsPage, readContact, throttle, upsertContact, QuoError, type ContactPerson } from './quo-api.ts';
import { syncContacts, type ContactsBook, type Due, type DueRow, type SyncDb } from './quo-contacts.ts';

// Quo contacts (migration 0190): the API mapping with a mocked fetch, and one run of the sync with a fake database.
// Fictional people and 555 numbers only.
const RIA: ContactPerson = { number: '+16475550142', first_name: 'Ria', last_name: 'Sample', email: 'ria@example.test', company: null, role: 'Renter' };

type Stored = { id: string; externalId: string | null; source: string | null; defaultFields: Record<string, unknown> };
function fakeQuo(start: Stored[] = []) {
  const store = new Map(start.map((c) => [c.id, c]));
  const calls: string[] = [];
  let n = 0;
  const f: typeof fetch = async (url, init) => {
    const u = new URL(String(url)); const m = init?.method ?? 'GET';
    calls.push(`${m} ${u.pathname}${u.search}`);
    assert.equal((init?.headers as Record<string, string>).authorization, 'k-test');
    const id = decodeURIComponent(u.pathname.split('/')[3] ?? '');
    if (m === 'GET' && u.pathname === '/v1/contacts') {
      const ext = u.searchParams.get('externalIds');
      const all = [...store.values()].filter((c) => !ext || c.externalId === ext);
      const size = Number(u.searchParams.get('maxResults') ?? 10);
      const from = Number(u.searchParams.get('pageToken') ?? 0);
      const page = all.slice(from, from + size);
      return new Response(JSON.stringify({ data: page, totalItems: all.length, nextPageToken: from + size < all.length ? String(from + size) : null }));
    }
    if (m === 'GET') return store.has(id) ? new Response(JSON.stringify({ data: store.get(id) })) : new Response(JSON.stringify({ message: 'The contact was not found' }), { status: 404 });
    if (m === 'POST') {
      const b = JSON.parse(String(init!.body)) as Stored;
      if ([...store.values()].some((c) => c.externalId === b.externalId && c.source === b.source)) return new Response(JSON.stringify({ message: 'Conflict' }), { status: 409 });
      const c = { ...b, id: `CT${++n}` }; store.set(c.id, c);
      return new Response(JSON.stringify({ data: c }), { status: 201 });
    }
    if (m === 'PATCH') {
      if (!store.has(id)) return new Response('{}', { status: 404 });
      const c = { ...store.get(id)!, ...JSON.parse(String(init!.body)) }; store.set(id, c);
      return new Response(JSON.stringify({ data: c }));
    }
    return new Response('{}', { status: 405 });
  };
  return { f, store, calls };
}

test('contacts: numbers are read as the database reads them', () => {
  assert.equal(e164('(647) 555-0142'), '+16475550142');
  assert.equal(e164('1 647 555 0142'), '+16475550142');
  assert.equal(e164('+44 20 7946 0958'), '+442079460958');
  assert.equal(e164('555-0142'), null);
  assert.equal(e164(null), null);
});

test('contacts: the fields sent (name, company, role, our number and email; what Quo already has is kept)', () => {
  assert.deepEqual(contactFields(RIA), {
    firstName: 'Ria', lastName: 'Sample', company: null, role: 'Renter',
    phoneNumbers: [{ name: 'mobile', value: '+16475550142' }], emails: [{ name: 'email', value: 'ria@example.test' }]
  });
  const existing = readContact({ id: 'CT9', defaultFields: { firstName: 'R', company: 'Sample Co', phoneNumbers: [{ name: 'work', value: '+1 (647) 555-0142' }, { name: 'home', value: '+14165550100' }],
    emails: [{ name: 'work', value: 'RIA@example.test' }, { name: 'old', value: null }] } });
  const f = contactFields({ ...RIA, role: null }, existing);
  assert.deepEqual(f.phoneNumbers, [{ name: 'work', value: '+1 (647) 555-0142' }, { name: 'home', value: '+14165550100' }], 'the same number is not added twice, the other kept');
  assert.deepEqual(f.emails, [{ name: 'work', value: 'RIA@example.test' }], 'the same email (any case) is not added twice');
  assert.equal(f.company, 'Sample Co', 'no company of ours: theirs stays');
  assert.equal(f.firstName, 'Ria');
});

test('contacts: create carries our external id and source; found again by it; the list pages', async () => {
  const q = fakeQuo();
  const o = { key: 'k-test', fetch: q.f };
  const c = await createContact(o, RIA, 'cc-16475550142');
  assert.equal(c.id, 'CT1');
  const body = q.store.get('CT1')!;
  assert.equal(body.externalId, 'cc-16475550142');
  assert.equal(body.source, 'carmacars');
  assert.equal((await findContactByExternalId(o, 'cc-16475550142'))?.id, 'CT1');
  assert.equal(await findContactByExternalId(o, 'cc-19995550100'), null);
  assert.ok(q.calls.some((x) => x.startsWith('GET /v1/contacts?externalIds=cc-16475550142&sources=carmacars&maxResults=1')));
  for (let i = 0; i < 60; i++) await createContact(o, { ...RIA, number: `+1647555${String(1000 + i)}` }, `cc-x${i}`);
  const p1 = await listContactsPage(o);
  assert.equal(p1.contacts.length, 50);
  const p2 = await listContactsPage(o, p1.next);
  assert.equal(p2.contacts.length, 11);
  assert.equal(p2.next, null);
});

test('contacts: upsert updates the contact we hold, finds a lost create by external id, makes a deleted one again', async () => {
  const q = fakeQuo([{ id: 'CTq', externalId: null, source: 'csv', defaultFields: { firstName: 'Old', phoneNumbers: [{ name: 'main', value: '+16475550142' }, { name: 'other', value: '+14165550111' }] } }]);
  const o = { key: 'k-test', fetch: q.f };
  assert.deepEqual(await upsertContact(o, RIA, 'CTq', 'cc-16475550142'), { id: 'CTq', action: 'updated' });
  const df = q.store.get('CTq')!.defaultFields as { firstName: string; phoneNumbers: unknown[] };
  assert.equal(df.firstName, 'Ria');
  assert.equal(df.phoneNumbers.length, 2, 'the other number someone added in Quo is kept');
  // no id held: a create (then the same external id is found, never a second contact)
  assert.deepEqual(await upsertContact(o, { ...RIA, number: '+16475550143' }, null, 'cc-16475550143'), { id: 'CT1', action: 'created' });
  assert.deepEqual(await upsertContact(o, { ...RIA, number: '+16475550143', first_name: 'Rhea' }, null, 'cc-16475550143'), { id: 'CT1', action: 'updated' });
  // deleted in Quo: made again
  q.store.delete('CTq');
  assert.deepEqual(await upsertContact(o, RIA, 'CTq', 'cc-16475550142'), { id: 'CT2', action: 'created' });
  assert.equal([...q.store.values()].filter((c) => c.externalId === 'cc-16475550143').length, 1);
});

test('contacts: a refused key and Quo\'s "slow down" are errors that tell the run to stop', async () => {
  const no: typeof fetch = async () => new Response(JSON.stringify({ message: 'Unauthorized' }), { status: 401 });
  await assert.rejects(upsertContact({ key: 'k-test', fetch: no }, RIA, null, 'cc-1'), (e: QuoError) => e.status === 401 && e.permanent);
  const busy: typeof fetch = async () => new Response('{}', { status: 429 });
  await assert.rejects(upsertContact({ key: 'k-test', fetch: busy }, RIA, null, 'cc-1'), (e: QuoError) => e.status === 429 && !e.permanent);
});

test('contacts: calls are spaced out', async () => {
  const waits: number[] = [];
  const f = throttle(async () => new Response('{}'), 150, async (ms) => { waits.push(ms); });
  await f('https://x.test/a'); await f('https://x.test/b'); await f('https://x.test/c');
  assert.equal(waits.length, 2);
  assert.ok(waits.every((w) => w > 100 && w <= 150));
});

// ---------------------------------------------------------------- one run of the sync
function fakeDb(rows: DueRow[], scan: Due['scan'] = { needed: false }) {
  const log: Array<[string, Record<string, unknown>]> = [];
  let scanNeeded = scan.needed;
  const waiting = [...rows];
  const db: SyncDb = {
    async due(limit) { const out = scanNeeded ? waiting.filter((r) => r.quo_id) : waiting.splice(0, limit); return { enabled: true, rows: out, scan: { needed: scanNeeded, cursor: null } }; },
    async found(p) { log.push(['found', p as unknown as Record<string, unknown>]); if (p.done) scanNeeded = false; return {}; },
    async done(p) { log.push(['done', p]); return {}; },
    async run(p) { log.push(['run', p]); return {}; }
  };
  return { db, log };
}
const row = (n: string, quoId: string | null = null): DueRow => ({ number: n, quo_id: quoId, hash: `h${n}`, dirty_at: '2026-10-27T12:00:00Z', external_id: `cc-${n.slice(1)}`, person: { ...RIA, number: n } });

test('sync: Quo\'s list is read first, then new people are created and the rest updated; each result goes back', async () => {
  const q = fakeQuo([{ id: 'CTq', externalId: null, source: 'csv', defaultFields: { firstName: 'Someone', phoneNumbers: [{ name: 'main', value: '+16475550144' }] } }]);
  const o = { key: 'k-test', fetch: q.f };
  const book: ContactsBook = { name: 'quo', ready: true,
    listPage: async (t) => { const p = await listContactsPage(o, t); return { contacts: p.contacts.map((c) => ({ id: c.id, phones: c.phones.map((x) => x.value) })), next: p.next }; },
    upsert: (p, id, ext) => upsertContact(o, p, id, ext) };
  const { db, log } = fakeDb([row('+16475550142'), row('+16475550145', 'CTq')], { needed: true });
  const r = await syncContacts(db, book);
  assert.equal(r.scanned, 1);
  assert.deepEqual(log.find(([k]) => k === 'found')![1], { contacts: [{ id: 'CTq', phones: ['+16475550144'] }], cursor: null, done: true });
  assert.equal(r.created, 1);
  assert.equal(r.updated, 1);
  const done = log.filter(([k]) => k === 'done').map(([, p]) => p);
  assert.deepEqual(done.map((p) => [p.number, p.ok, p.quo_id, p.hash]), [['+16475550145', true, 'CTq', 'h+16475550145'], ['+16475550142', true, 'CT1', 'h+16475550142']]);
  assert.equal(log.at(-1)![0], 'run');
  assert.equal(log.at(-1)![1].ok, true);
});

test('sync: no key: nothing is called, the run records why (the job pauses)', async () => {
  const { db, log } = fakeDb([row('+16475550142')]);
  const r = await syncContacts(db, { name: 'quo', ready: false, missing: 'QUO_API_KEY is not set', listPage: async () => assert.fail('no call'), upsert: async () => assert.fail('no call') });
  assert.equal(r.skipped, 'QUO_API_KEY is not set');
  assert.deepEqual(log, [['run', { ok: false, paused_reason: 'QUO_API_KEY is not set' }]]);
});

test('sync: one person refused is recorded and the others go on; a 429 or a refused key stops the run', async () => {
  let n = 0;
  const book: ContactsBook = { name: 'quo', ready: true, listPage: async () => ({ contacts: [], next: null }),
    upsert: async (p) => { n++; if (p.number === '+16475550142') throw new QuoError('Quo 400: invalid phone', 400, null, true); return { id: `CT${n}`, action: 'created' }; } };
  const a = fakeDb([row('+16475550142'), row('+16475550143')]);
  const r = await syncContacts(a.db, book);
  assert.deepEqual([r.created, r.failed], [1, 1]);
  const bad = a.log.find(([k, p]) => k === 'done' && p.ok === false)![1];
  assert.equal(bad.permanent, true);
  assert.match(String(bad.error), /invalid phone/);

  const slow: ContactsBook = { ...book, upsert: async () => { throw new QuoError('Quo 429: slow down', 429, null, false); } };
  const b = fakeDb([row('+16475550146'), row('+16475550147')]);
  const r2 = await syncContacts(b.db, slow);
  assert.equal(r2.rate_limited, true);
  assert.equal(b.log.filter(([k]) => k === 'done').length, 0, 'nothing is marked failed: the numbers go again later');
  assert.equal(b.log.at(-1)![1].rate_limited, true);

  const refused: ContactsBook = { ...book, upsert: async () => { throw new QuoError('Quo 401: Unauthorized', 401, null, true); } };
  const c = fakeDb([row('+16475550148')]);
  const r3 = await syncContacts(c.db, refused);
  assert.match(String(r3.error), /refused the key/);
  assert.match(String(c.log.at(-1)![1].paused_reason), /refused the key/);
});

test('sync: a run stops at its time budget', async () => {
  let t = 0;
  const book: ContactsBook = { name: 'fake', ready: true, listPage: async () => ({ contacts: [], next: null }), upsert: async () => { t += 20_000; return { id: 'CT', action: 'updated' }; } };
  const { db } = fakeDb([row('+16475550142'), row('+16475550143'), row('+16475550144'), row('+16475550145')]);
  const r = await syncContacts(db, book, { budgetMs: 45_000, now: () => t });
  assert.equal(r.updated, 3);
});
