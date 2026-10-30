// Quo contacts that match the site (migration 0190): one run of the sync, with the database and Quo passed in, so the
// unit tests drive it with a mocked fetch and a fake database. The database decides who goes to Quo and with which
// name (public.server_quo_contacts_due); this file reads Quo's list once (to take over contacts Quo already has), then
// creates or updates each person, politely: calls spaced out, a stop at Quo's "slow down" (429) or a refused key, and a
// time budget per run. Nothing here blocks a booking: the run is the five-minute phone job's.
import { QuoError, type ContactPerson } from './quo-api.ts';

export interface ContactsBook {
  readonly name: 'quo' | 'fake';
  /** false when the key is missing: the run only records why. */
  readonly ready: boolean;
  readonly missing?: string | null;
  listPage(token: string | null): Promise<{ contacts: Array<{ id: string; phones: string[] }>; next: string | null }>;
  upsert(p: ContactPerson, quoId: string | null, externalId: string): Promise<{ id: string; action: 'created' | 'updated' }>;
}

export interface DueRow { number: string; quo_id: string | null; hash: string; dirty_at: string | null; external_id: string; person: ContactPerson & { kind?: string; ref_id?: string } }
export interface Due { enabled: boolean; paused?: boolean; rows: DueRow[]; waiting_for_scan?: number; scan: { needed: boolean; cursor?: string | null } }
export interface SyncDb {
  due(limit: number): Promise<Due>;
  found(p: { contacts: Array<{ id: string; phones: string[] }>; cursor: string | null; done: boolean }): Promise<unknown>;
  done(p: Record<string, unknown>): Promise<unknown>;
  run(p: Record<string, unknown>): Promise<unknown>;
}
export interface SyncResult { ok: boolean; skipped?: string; created: number; updated: number; failed: number; scanned: number; rate_limited: boolean; error: string | null }

const msg = (e: unknown) => (e instanceof Error ? e.message : String(e)).slice(0, 300);
/** A refusal of the key itself (401, 403): every call would fail the same way, so the run stops and the sync pauses. */
const keyRefused = (e: unknown) => e instanceof QuoError && (e.status === 401 || e.status === 403);

export async function syncContacts(db: SyncDb, book: ContactsBook, o: { limit?: number; scanPages?: number; budgetMs?: number; now?: () => number } = {}): Promise<SyncResult> {
  const now = o.now ?? Date.now;
  const start = now();
  const budget = o.budgetMs ?? 45_000;
  const limit = o.limit ?? 40;
  const r: SyncResult = { ok: true, created: 0, updated: 0, failed: 0, scanned: 0, rate_limited: false, error: null };
  if (!book.ready) {
    const why = book.missing || 'QUO_API_KEY is not set';
    await db.run({ ok: false, paused_reason: why });
    return { ...r, skipped: why };
  }
  const due = await db.due(limit);
  if (!due.enabled) return { ...r, skipped: 'off' };
  if (due.paused) return { ...r, skipped: 'paused' };
  if (!due.scan.needed && !due.rows.length) return { ...r, skipped: 'nothing due' };
  let rows = due.rows;
  let paused: string | null = null;

  // the one-time read of Quo's list, a few pages a run
  if (due.scan.needed) {
    let cursor = due.scan.cursor ?? null;
    for (let i = 0; i < (o.scanPages ?? 10) && now() - start < budget; i++) {
      let page: { contacts: Array<{ id: string; phones: string[] }>; next: string | null };
      try { page = await book.listPage(cursor); } catch (e) {
        if (e instanceof QuoError && e.status === 429) r.rate_limited = true;
        else if (keyRefused(e)) paused = `Quo refused the key: ${msg(e)}`;
        else r.error = `Reading Quo's contacts: ${msg(e)}`;
        break;
      }
      cursor = page.next;
      await db.found({ contacts: page.contacts, cursor, done: !cursor });
      r.scanned += page.contacts.length;
      if (!cursor) {
        // the list is read: the people who waited for it go now
        const more = await db.due(Math.max(0, limit - rows.length));
        rows = rows.concat(more.rows.filter((x) => !rows.some((y) => y.number === x.number)));
        break;
      }
    }
  }

  for (const row of rows) {
    if (r.rate_limited || paused || now() - start >= budget) break; // the rest stay leased for 10 minutes, then go again
    try {
      const u = await book.upsert(row.person, row.quo_id, row.external_id);
      await db.done({ number: row.number, ok: true, quo_id: u.id, hash: row.hash, dirty_at: row.dirty_at, person: row.person });
      if (u.action === 'created') r.created++; else r.updated++;
    } catch (e) {
      if (keyRefused(e)) { paused = `Quo refused the key: ${msg(e)}`; break; }
      if (e instanceof QuoError && e.status === 429) { r.rate_limited = true; break; }
      r.failed++;
      await db.done({ number: row.number, ok: false, error: msg(e), permanent: e instanceof QuoError ? e.permanent : false, dirty_at: row.dirty_at });
    }
  }
  r.ok = !paused && !r.error;
  await db.run({ ok: r.ok, created: r.created, updated: r.updated, failed: r.failed, scanned: r.scanned, rate_limited: r.rate_limited, error: r.error, paused_reason: paused });
  return paused ? { ...r, error: paused } : r;
}
