// calendar-sync: reads the calendar links of other platforms (Getaround, Google Calendar, others; Turo has no calendar link and comes by email, migration 0063) for every car and keeps their
// trips as External booking blocks (docs/changes/2026-10-19-calendar-sync-recovery-uptime.md). Called every 5 minutes
// by pg_cron through pg_net (job `carmacars-calendar-sync`, scheduled by the deploy: scripts/deploy/supabase.sh
// calsync) with `Authorization: Bearer <CALSYNC_JOB_TOKEN>`; any other caller gets 403. The database decides which
// links are due (app.calendar_feeds_due: calendar_sync_minutes, 10 by default). The run and the reader are the site's
// own files, web/src/features/calendar/sync-run.ts and ical.ts, which the deploy copies beside this file as run.ts
// and ical.ts (the same code the site's "Sync now" and the unit tests use).
//
// Secrets (Edge Function secrets, set by the deploy): CALSYNC_JOB_TOKEN. SUPABASE_DB_URL is provided.
import postgres from 'npm:postgres@3.4.5';
import { syncDue, type DueFeed, type Store } from './run.ts';

const TOKEN = Deno.env.get('CALSYNC_JOB_TOKEN') ?? '';
const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false, idle_timeout: 20, onnotice: () => {} });

const store: Store = {
  async due(limit) {
    const [r] = await sql`select app.calendar_feeds_due(${limit}::int) as feeds`;
    return (r?.feeds ?? []) as DueFeed[];
  },
  async ok(id, events, meta) {
    const [r] = await sql`select app.calendar_feed_apply(${id}::uuid, ${events === null ? null : JSON.stringify(events)}::text::jsonb, ${JSON.stringify(meta)}::text::jsonb) as r`;
    return r?.r;
  },
  async failed(id, error) {
    const [r] = await sql`select app.calendar_feed_failed(${id}::uuid, ${error}) as r`;
    return r?.r;
  }
};

Deno.serve(async (req) => {
  if (!TOKEN || req.headers.get('authorization') !== `Bearer ${TOKEN}`) return new Response('Forbidden', { status: 403 });
  try {
    const r = await syncDue(store, (u, init) => fetch(u, init));
    return Response.json({ ok: true, ...r });
  } catch (e) {
    return Response.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 500) : 'failed' }, { status: 500 });
  }
});
