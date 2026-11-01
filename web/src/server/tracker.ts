import 'server-only';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { MAX_BODY_BYTES, readBatch, verify, type HeaderGet } from '@/integrations/tracker/ingest';
import type { Json } from '@/lib/db/types';

// The tracker ingest (migration 0400): checks the signature before the database is touched, then one database call per
// batch (app.tracker_ingest: the hot row, the thinned history, trips and alerts). The ingest key is read from the vault
// once and kept 5 minutes in this Worker instance (outside production, read every time: the tests change it); a
// signature that fails with a kept key reads the key again once, so a new key works at once.
const SR = { role: 'service_role' as const };
let kept: { at: number; key: string | null } | null = null;

async function ingestKey(fresh = false): Promise<string | null> {
  const keep = env().APP_ENV === 'production' ? 300_000 : 0;
  if (!fresh && kept && Date.now() - kept.at < keep) return kept.key;
  const key = (await rpc('server_tracker_ingest_key', {} as never, SR)) as unknown as string | null;
  kept = { at: Date.now(), key: key || null };
  return kept.key;
}

export interface IngestResult { status: number; body: Record<string, unknown> }

export async function handleTrackerIngest(raw: string, header: HeaderGet, format = 'generic'): Promise<IngestResult> {
  if (raw.length > MAX_BODY_BYTES) return { status: 413, body: { error: 'too large' } };
  let key = await ingestKey();
  if (!key) return { status: 503, body: { error: 'tracker ingest is not set up: make the ingest key in Admin > Cars > Fleet tracking' } };
  let v = await verify(raw, header, key);
  if (!v.ok && v.reason === 'signature' && kept && Date.now() - kept.at > 30_000) { key = await ingestKey(true); v = await verify(raw, header, key); }
  if (!v.ok) return { status: 401, body: { error: v.reason } };
  const batch = readBatch(raw, format);
  if (!batch.ok) return { status: 400, body: { error: batch.error } };
  if (!batch.points.length) return { status: 200, body: { received: batch.sent, accepted: 0 } };
  const r = (await rpc('server_tracker_ingest', { p: { points: batch.points } as unknown as Json }, SR)) as unknown as Record<string, unknown>;
  return { status: 200, body: { ...r, received: batch.sent } };
}
