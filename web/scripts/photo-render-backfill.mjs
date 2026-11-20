#!/usr/bin/env node
// Release 48 AN (3150): the one-shot render backfill. Puts every published real car on the backfill list (the job then does
// those cars first: the side profile, the front three-quarter, the other standard angles, then the real photos' branded
// background), turns the switches on and queues the first batch now. Spend stays under the image model's daily limit less
// the reserve (Program settings). Safe to run again: it only re-lists the cars.
//
//   node scripts/photo-render-backfill.mjs            start it (prints the cars listed and the first run)
//   node scripts/photo-render-backfill.mjs --status   its progress
//
// Reaches the database the way the site does: DATABASE_URL (the company server, or the local stack), else the Supabase
// API (NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY). The Admin can also start it: ops_do photo_render_backfill.
const status = process.argv.includes('--status');
const sql = status ? 'select app.photo_render_backfill_read() as r' : 'select public.photo_render_backfill() as r';

async function viaPostgres(url) {
  const { default: postgres } = await import('postgres');
  const db = postgres(url, { max: 1, idle_timeout: 5 });
  try { return (await db.unsafe(sql))[0].r; } finally { await db.end(); }
}
async function viaApi(base, key) {
  if (status) throw new Error('--status needs DATABASE_URL (or read it in the Admin: ops_read photo_render_backfill)');
  const r = await fetch(`${base.replace(/\/$/, '')}/rest/v1/rpc/photo_render_backfill`, {
    method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: '{}'
  });
  if (!r.ok) throw new Error(`the database API answered ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

const url = process.env.DATABASE_URL, base = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
try {
  const out = url ? await viaPostgres(url) : base && key ? await viaApi(base, key) : null;
  if (!out) { console.error('Set DATABASE_URL, or NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY'); process.exit(2); }
  console.log(JSON.stringify(out, null, 2));
} catch (e) {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
}
