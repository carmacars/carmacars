import 'server-only';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { MAX_BODY_BYTES, badSender, readBatch, verify, type HeaderGet } from '@/integrations/tracker/ingest';
import type { Json } from '@/lib/db/types';

// The tracker ingest (migration 0400): checks the signature before the database is touched, then one database call per
// batch (app.tracker_ingest: the hot row, the thinned history, trips and alerts). The ingest key is read from the vault
// once and kept 5 minutes in this Worker instance (outside production, read every time: the tests change it); a
// signature that fails with a kept key reads the key again once, so a new key works at once.
// 3320: a request is taken once (the database keeps each accepted signature 10 minutes: 409 replay) and at most
// tracker_settings.ingest_per_minute a minute (429 rate; the relay retries). Before the signature is checked, a sender
// that keeps failing it is refused in this Worker instance for the rest of the minute (BAD_PER_MINUTE), so a flood of
// unsigned requests costs no database call and no HMAC.
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

export async function handleTrackerIngest(raw: string, header: HeaderGet, format = 'generic', sender = 'unknown'): Promise<IngestResult> {
  if (raw.length > MAX_BODY_BYTES) return { status: 413, body: { error: 'too large' } };
  if (badSender(sender)) return { status: 429, body: { error: 'too many bad signatures: wait a minute' } };
  let key = await ingestKey();
  if (!key) return { status: 503, body: { error: 'tracker ingest is not set up: make the ingest key in Admin > Cars > Fleet tracking' } };
  let v = await verify(raw, header, key);
  if (!v.ok && v.reason === 'signature' && kept && Date.now() - kept.at > 30_000) { key = await ingestKey(true); v = await verify(raw, header, key); }
  if (!v.ok) { badSender(sender, true); return { status: 401, body: { error: v.reason } }; }
  const batch = readBatch(raw, format);
  if (!batch.ok) return { status: 400, body: { error: batch.error } };
  const r = (await rpc('server_tracker_ingest_signed', { p: { points: batch.points } as unknown as Json, p_sig: v.sig ?? '', p_ts: v.ts ?? 0 }, SR)) as unknown as Record<string, unknown>;
  if (r.refused === 'replay') return { status: 409, body: { error: 'replay: this signed request was already taken' } };
  if (r.refused === 'rate') return { status: 429, body: { error: 'too many requests this minute' } };
  if (r.refused) return { status: 401, body: { error: String(r.refused) } };
  return { status: 200, body: { ...r, received: batch.sent } };
}
