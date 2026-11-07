// Instant notifications (r32, src/lib/edge/notify-kick.ts): a write asks the database at once (debounced per isolate),
// the push and text jobs run only when due, and the cron minute plan keeps the other jobs on their five-minute turn.
// Placeholder strings stand in for the keys; nothing here is a real key.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { KICK_GAP_MS, askDue, kickNow, kickable, notifyKick, resetKick, tickPlan } from './notify-kick.ts';

const DB = { DATA_BACKEND: 'supabase', NEXT_PUBLIC_SUPABASE_URL: 'https://db.example.test', SUPABASE_SERVICE_ROLE_KEY: 'service-placeholder' };
const KEYS = { VAPID_PUBLIC_KEY: 'public-placeholder', VAPID_PRIVATE_KEY: 'private-placeholder' };
const answer = (o: unknown, status = 200) => (async () => new Response(JSON.stringify(o), { status })) as unknown as typeof fetch;

test('the paths that never kick', () => {
  for (const p of ['/api/t', '/api/jobs/push', '/api/email/send', '/api/health', '/_next/x', '/media/a.jpg']) assert.equal(kickable(p), false, p);
  for (const p of ['/book/abc', '/api/stripe/webhook', '/admin/bookings/1', '/contact']) assert.equal(kickable(p), true, p);
});

test('askDue: the database decides; no database or an error: nothing', async () => {
  assert.equal(await askDue({}, answer({})), null);
  assert.equal(await askDue(DB, answer({}, 500)), null);
  let body = '';
  const f = (async (_u: string, i: RequestInit) => { body = String(i.body); return new Response(JSON.stringify({ push: true, phone: true, email: false, events: 2 })); }) as unknown as typeof fetch;
  assert.deepEqual(await askDue({ ...DB, ...KEYS }, f), { push: true, phone: true, email: false, events: 2 });
  assert.equal(body, '{"p_kinds":["web"]}');
  assert.equal((await askDue(DB, answer({ push: true })))!.push, false, 'no keys: no push');
});

test('kickNow runs only the jobs due', async () => {
  const ran: string[] = [];
  await kickNow({ ...DB, ...KEYS }, async (p) => { ran.push(p); }, answer({ push: true, phone: false, email: true, events: 0 }));
  assert.deepEqual(ran, ['/api/jobs/push']);
  ran.length = 0;
  await kickNow(DB, async (p) => { ran.push(p); }, answer({ push: false, phone: true }));
  assert.deepEqual(ran, ['/api/jobs/phone']);
});

test('a burst of writes asks at once, then once more after the gap', async () => {
  resetKick();
  let t = 10_000;
  const waits: Promise<unknown>[] = [];
  const sleeps: number[] = [];
  let asked = 0;
  const f = (async () => { asked++; return new Response('{"push":false,"phone":false,"email":false,"events":0}'); }) as unknown as typeof fetch;
  const o = { now: () => t, sleep: async (ms: number) => { sleeps.push(ms); }, fetch: f };
  const ctx = { waitUntil: (p: Promise<unknown>) => { waits.push(p); } };
  assert.equal(notifyKick('/book/x', DB, ctx, async () => undefined, o), 'now');
  t += 100;
  assert.equal(notifyKick('/book/x', DB, ctx, async () => undefined, o), 'later');
  assert.equal(notifyKick('/book/x', DB, ctx, async () => undefined, o), 'skipped', 'one trailing ask at most');
  assert.equal(notifyKick('/api/t', DB, ctx, async () => undefined, o), 'skipped');
  await Promise.all(waits);
  assert.equal(asked, 2);
  assert.deepEqual(sleeps, [KICK_GAP_MS - 100]);
  t += KICK_GAP_MS * 2;
  assert.equal(notifyKick('/book/x', DB, ctx, async () => undefined, o), 'now');
});

test('the cron plan: the jobs every fifth minute, the minutes between only the notices', () => {
  const at = (m: number) => Date.UTC(2026, 10, 7, 12, m, 0);
  assert.deepEqual(tickPlan(at(0)), { full: true, minute: 0 });
  assert.deepEqual(tickPlan(at(5)), { full: true, minute: 5 });
  assert.deepEqual(tickPlan(at(7)), { full: false, minute: 7 });
  assert.equal([...Array(60).keys()].filter((m) => tickPlan(at(m)).full).length, 12, 'twelve full ticks an hour, as before');
});
