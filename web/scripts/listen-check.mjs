// Release 48 (docs/changes/2026-11-14-r48-instant-send.md): checks, on a test database, that a queued text reaches a
// LISTEN on carmacars_send at once (migration 2980) and how long it took. It queues one test text for tomorrow (so no job
// sends it), waits for its notify, then marks it skipped. Never run against the live database.
//
//   DATABASE_URL=postgresql://postgres@127.0.0.1:54322/carmacars node scripts/listen-check.mjs
//   LISTEN_URL=...   optional: listen as another login (the server's carmacars_listen) while DATABASE_URL queues
import postgres from 'postgres';

const url = process.env.DATABASE_URL;
if (!url) { console.error('Set DATABASE_URL to a test database'); process.exit(2); }
if (process.env.APP_ENV === 'production') { console.error('Not on the live database'); process.exit(2); }
const listenUrl = process.env.LISTEN_URL || url;

const listen = postgres(listenUrl, { max: 1, idle_timeout: null, onnotice: () => {} });
const sql = postgres(url, { max: 1, onnotice: () => {} });
let resolve;
const got = new Promise((r) => { resolve = r; });
let id = null;
const seen = [];
await listen.listen('carmacars_send', (payload) => { seen.push(payload); if (id && payload === `phone_outbox:${id}`) resolve(Date.now()); });

const t0 = Date.now();
const [row] = await sql`select (app.phone_outbox_put('+14165550100', 'CarmaCars: listen check (test, not sent)', 'staff', null, null, 'listen_check', null,
  ${'listen-check:' + t0}, now() + interval '1 day')).id as id`;
id = row?.id ?? null;
if (!id) { console.error('No test text was queued (the number may be opted out)'); process.exit(1); }
if (seen.includes(`phone_outbox:${id}`)) resolve(Date.now());
const at = await Promise.race([got, new Promise((r) => setTimeout(() => r(null), 5000))]);
await sql`update phone_outbox set status = 'skipped', status_reason = 'listen check' where id = ${id}`;
await Promise.all([listen.end({ timeout: 1 }), sql.end({ timeout: 1 })]);
if (at === null) { console.error(`FAIL: no notify for phone_outbox:${id} within 5 s (seen: ${seen.length})`); process.exit(1); }
console.log(`ok: phone_outbox:${id} reached the listen in ${at - t0} ms (queue to notify, after commit)`);
