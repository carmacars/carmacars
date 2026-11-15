// The Quo public API (formerly OpenPhone), migration 0085. No imports: used by the Worker (sending texts), by the
// deploy script (scripts/deploy/quo.mjs, the webhook) and by the unit tests with a mocked fetch.
//
//   POST /v1/messages                   send a text: {content, from (E.164 or PN id), to: [E.164]}; 202 with data.id
//   GET  /v1/phone-numbers              the workspace's numbers: data[] {id (PN...), number (E.164), name}
//   GET  /webhooks                      (Quo-Api-Version: 2026-03-30) data[] {id, url, events, resourceIds, status}
//   POST /webhooks                      {url, events, resourceIds, label, status}; 201 data.key is the signing secret (whsec_)
//   PATCH /webhooks/{id}                events, resourceIds, url, status, label
//   POST /webhooks/{id}/rotate          data.key, a new signing secret
// The key goes in the Authorization header as it is (no "Bearer"). Errors carry {message, code, status}.

export const QUO_API_VERSION = '2026-03-30';
export const DEFAULT_QUO_BASE = 'https://api.openphone.com';

export interface QuoOptions { key: string; base?: string; fetch?: typeof fetch; timeoutMs?: number }
export class QuoError extends Error {
  readonly status: number;
  readonly code: string | null;
  readonly permanent: boolean;
  constructor(message: string, status: number, code: string | null, permanent: boolean) {
    super(message); this.name = 'QuoError'; this.status = status; this.code = code; this.permanent = permanent;
  }
}

async function call<T>(o: QuoOptions, method: string, path: string, body?: unknown, versioned = false): Promise<T> {
  const f = o.fetch ?? fetch;
  const headers: Record<string, string> = { authorization: o.key, accept: 'application/json' };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (versioned) headers['quo-api-version'] = QUO_API_VERSION;
  let r: Response;
  try {
    r = await f(`${(o.base || DEFAULT_QUO_BASE).replace(/\/$/, '')}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(o.timeoutMs ?? 10_000) });
  } catch (e) {
    throw new QuoError(`Quo did not answer: ${e instanceof Error ? e.message : String(e)}`.slice(0, 300), 0, null, false);
  }
  const text = await r.text();
  let j: unknown = null;
  try { j = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (!r.ok) {
    const e = (j ?? {}) as { message?: string; code?: string; title?: string; error?: { message?: string } };
    const msg = e.message ?? e.error?.message ?? e.title ?? text.slice(0, 200) ?? `HTTP ${r.status}`;
    // 400 (bad number, A2P not approved), 401, 402, 403 and 404 will not get better by trying again; 429 and 5xx may
    throw new QuoError(`Quo ${r.status}: ${msg}`.slice(0, 300), r.status, e.code ?? null, r.status >= 400 && r.status < 500 && r.status !== 429 && r.status !== 408);
  }
  return j as T;
}

export interface SentText { id: string | null; status: string | null; conversationId: string | null }
export async function sendText(o: QuoOptions, p: { from: string; to: string; content: string; userId?: string | null }): Promise<SentText> {
  const content = p.content.trim();
  if (!content) throw new QuoError('Empty text', 400, null, true);
  const j = await call<{ data?: { id?: string; status?: string; conversationId?: string } }>(o, 'POST', '/v1/messages',
    { content: content.slice(0, 1600), from: p.from, to: [p.to], ...(p.userId ? { userId: p.userId } : {}) });
  return { id: j?.data?.id ?? null, status: j?.data?.status ?? null, conversationId: j?.data?.conversationId ?? null };
}

export interface QuoNumber { id: string; number: string; name: string | null }
export async function listNumbers(o: QuoOptions): Promise<QuoNumber[]> {
  const j = await call<{ data?: Array<{ id: string; number?: string; phoneNumber?: string; formattedNumber?: string; name?: string | null }> }>(o, 'GET', '/v1/phone-numbers');
  return (j?.data ?? []).map((n) => ({ id: n.id, number: n.number ?? n.phoneNumber ?? n.formattedNumber ?? '', name: n.name ?? null }));
}

export interface QuoWebhook { id: string; url: string; events: string[]; resourceIds: string[]; status: string; label: string | null; key?: string }
export async function listWebhooks(o: QuoOptions): Promise<QuoWebhook[]> {
  return (await call<{ data?: QuoWebhook[] }>(o, 'GET', '/webhooks', undefined, true))?.data ?? [];
}
export async function createWebhook(o: QuoOptions, p: { url: string; events: string[]; resourceIds: string[]; label: string }): Promise<QuoWebhook> {
  const j = await call<{ data: QuoWebhook }>(o, 'POST', '/webhooks', { ...p, status: 'enabled' }, true);
  return j.data;
}
export async function updateWebhook(o: QuoOptions, id: string, p: Partial<{ url: string; events: string[]; resourceIds: string[]; label: string; status: string }>): Promise<QuoWebhook> {
  return (await call<{ data: QuoWebhook }>(o, 'PATCH', `/webhooks/${encodeURIComponent(id)}`, p, true)).data;
}
export async function rotateWebhook(o: QuoOptions, id: string): Promise<string> {
  return (await call<{ data: { key: string } }>(o, 'POST', `/webhooks/${encodeURIComponent(id)}/rotate`, undefined, true)).data.key;
}

/** One idempotent setup of our webhook: found by its URL, events and number kept current; created (or its key
 *  rotated when we no longer hold it) only when needed. Returns the key when a new one was issued. */
export async function ensureWebhook(o: QuoOptions, p: { url: string; events: string[]; resourceIds: string[]; label: string; haveKey: boolean }):
  Promise<{ id: string; action: 'created' | 'updated' | 'kept' | 'rotated'; key: string | null }> {
  const all = await listWebhooks(o);
  const mine = all.filter((w) => w.url === p.url);
  const w = mine[0];
  if (!w) {
    const c = await createWebhook(o, { url: p.url, events: p.events, resourceIds: p.resourceIds, label: p.label });
    return { id: c.id, action: 'created', key: c.key ?? null };
  }
  const same = (a: string[], b: string[]) => a.length === b.length && [...a].sort().join() === [...b].sort().join();
  let action: 'updated' | 'kept' = 'kept';
  if (!same(w.events ?? [], p.events) || !same(w.resourceIds ?? [], p.resourceIds) || w.status !== 'enabled') {
    await updateWebhook(o, w.id, { events: p.events, resourceIds: p.resourceIds, status: 'enabled', label: p.label });
    action = 'updated';
  }
  if (!p.haveKey) return { id: w.id, action: 'rotated', key: await rotateWebhook(o, w.id) };
  return { id: w.id, action, key: null };
}

// ---------------------------------------------------------------- contacts (migration 0190)
//   GET   /v1/contacts?maxResults=50&pageToken=...      the workspace's contacts: data[], nextPageToken (no phone filter)
//   GET   /v1/contacts?externalIds=cc-...&maxResults=1  ours, by the external id we gave it
//   GET   /v1/contacts/{id}                             one contact (404: deleted in Quo)
//   POST  /v1/contacts                                  {defaultFields: {firstName, lastName, company, role, emails, phoneNumbers}, externalId, source}
//   PATCH /v1/contacts/{id}                             the same fields
// Quo allows 10 requests a second per key; the sync spaces its calls (throttle below) and stops at a 429.

export const CONTACT_SOURCE = 'carmacars';
/** What Quo should hold for one person (from public.server_quo_contacts_due). */
export interface ContactPerson { number: string; first_name: string; last_name: string | null; email: string | null; company: string | null; role: string | null }
export interface QuoContact { id: string; externalId: string | null; firstName: string | null; lastName: string | null; company: string | null; role: string | null;
  phones: Array<{ name: string; value: string }>; emails: Array<{ name: string; value: string }> }
type RawItem = { name?: string; value?: string | null };
type RawContact = { id: string; externalId?: string | null; defaultFields?: { firstName?: string | null; lastName?: string | null; company?: string | null; role?: string | null;
  phoneNumbers?: RawItem[] | null; emails?: RawItem[] | null } };

/** "+16475550100" from what Quo or a person wrote; null when it is not a phone number (as app.phone_e164). */
export function e164(p: string | null | undefined): string | null {
  const raw = String(p ?? '').trim();
  const d = raw.replace(/[^0-9]/g, '');
  if (/^[2-9][0-9]{9}$/.test(d)) return `+1${d}`;
  if (/^1[2-9][0-9]{9}$/.test(d)) return `+${d}`;
  if (raw.startsWith('+') && d.length >= 8 && d.length <= 15) return `+${d}`;
  return null;
}

export function readContact(c: RawContact): QuoContact {
  const f = c.defaultFields ?? {};
  const list = (xs: RawItem[] | null | undefined) =>
    (xs ?? []).filter((x) => typeof x?.value === 'string' && x.value.trim()).map((x) => ({ name: x.name || 'other', value: String(x.value) }));
  return { id: c.id, externalId: c.externalId ?? null, firstName: f.firstName ?? null, lastName: f.lastName ?? null, company: f.company ?? null, role: f.role ?? null,
    phones: list(f.phoneNumbers), emails: list(f.emails) };
}

/** The fields we send: our name, company and role; our number and email added to the ones the contact already has
 *  (a number or email someone added in Quo is kept). */
export function contactFields(p: ContactPerson, existing?: QuoContact | null) {
  const phones = [...(existing?.phones ?? [])];
  if (!phones.some((x) => e164(x.value) === p.number)) phones.unshift({ name: 'mobile', value: p.number });
  const emails = [...(existing?.emails ?? [])];
  const email = p.email?.trim() || null;
  if (email && !emails.some((x) => x.value.trim().toLowerCase() === email.toLowerCase())) emails.unshift({ name: 'email', value: email });
  return {
    firstName: p.first_name, lastName: p.last_name ?? null,
    company: p.company ?? existing?.company ?? null, role: p.role ?? existing?.role ?? null,
    phoneNumbers: phones, emails
  };
}

export async function getContact(o: QuoOptions, id: string): Promise<QuoContact | null> {
  try {
    const j = await call<{ data?: RawContact }>(o, 'GET', `/v1/contacts/${encodeURIComponent(id)}`);
    return j?.data?.id ? readContact(j.data) : null;
  } catch (e) {
    if (e instanceof QuoError && e.status === 404) return null;
    throw e;
  }
}

export async function findContactByExternalId(o: QuoOptions, externalId: string): Promise<QuoContact | null> {
  const q = new URLSearchParams({ externalIds: externalId, sources: CONTACT_SOURCE, maxResults: '1' });
  const j = await call<{ data?: RawContact[] }>(o, 'GET', `/v1/contacts?${q}`);
  const c = (j?.data ?? []).find((x) => x?.externalId === externalId);
  return c ? readContact(c) : null;
}

export async function listContactsPage(o: QuoOptions, pageToken?: string | null): Promise<{ contacts: QuoContact[]; next: string | null }> {
  const q = new URLSearchParams({ maxResults: '50' });
  if (pageToken) q.set('pageToken', pageToken);
  const j = await call<{ data?: RawContact[]; nextPageToken?: string | null }>(o, 'GET', `/v1/contacts?${q}`);
  return { contacts: (j?.data ?? []).filter((c) => c?.id).map(readContact), next: j?.nextPageToken || null };
}

export async function createContact(o: QuoOptions, p: ContactPerson, externalId: string): Promise<QuoContact> {
  const j = await call<{ data: RawContact }>(o, 'POST', '/v1/contacts', { defaultFields: contactFields(p), externalId, source: CONTACT_SOURCE });
  if (!j?.data?.id) throw new QuoError('Quo answered without a contact id', 502, null, false);
  return readContact(j.data);
}

export async function updateContact(o: QuoOptions, id: string, p: ContactPerson, existing: QuoContact | null): Promise<QuoContact> {
  const j = await call<{ data?: RawContact }>(o, 'PATCH', `/v1/contacts/${encodeURIComponent(id)}`, { defaultFields: contactFields(p, existing) });
  return j?.data?.id ? readContact(j.data) : { ...(existing ?? readContact({ id })), id };
}

/** One person into Quo: the contact we hold (read first, so its other numbers and emails are kept), else ours by its
 *  external id (a create whose answer was lost), else a new one. A contact deleted in Quo is made again. */
export async function upsertContact(o: QuoOptions, p: ContactPerson, quoId: string | null, externalId: string):
  Promise<{ id: string; action: 'created' | 'updated' }> {
  let existing = quoId ? await getContact(o, quoId) : null;
  if (!existing) existing = await findContactByExternalId(o, externalId);
  if (existing) return { id: (await updateContact(o, existing.id, p, existing)).id, action: 'updated' };
  try {
    return { id: (await createContact(o, p, externalId)).id, action: 'created' };
  } catch (e) {
    // 409: a contact with this source and external id exists (made by a run whose answer was lost): update it
    if (!(e instanceof QuoError && e.status === 409)) throw e;
    const again = await findContactByExternalId(o, externalId);
    if (!again) throw e;
    return { id: (await updateContact(o, again.id, p, again)).id, action: 'updated' };
  }
}

/** A fetch that waits so calls are at least gapMs apart (Quo: 10 a second per key). */
export function throttle(f: typeof fetch, gapMs: number, sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms))): typeof fetch {
  let last = 0;
  return (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const wait = last + gapMs - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    return f(input, init);
  }) as typeof fetch;
}

// ---------------------------------------------------------------- a call's recording, transcript and summary (r48, 2995)
//   GET /v1/call-recordings/{callId}   data[] {id, url, duration, type, status}
//   GET /v1/call-transcripts/{callId}  data {dialogue[] {content, start, end, identifier, userId}, status}
//   GET /v1/call-summaries/{callId}    data {summary[], nextSteps[], status}
// The backfill of calls whose webhook never brought them. A 404 means Quo has none (recording off, no AI on the plan).
export interface QuoCallMedia {
  recordings: Array<{ id: string | null; url: string; duration: number | null; type: string | null }>;
  transcript: Array<{ who: 'us' | 'them'; text: string; start: number | null; end: number | null }>;
  summary: string[]; next_steps: string[];
}
type Raw = Record<string, unknown>;
const rawObj = (v: unknown): Raw => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Raw) : {});
const rawArr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const rawStr = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : null);
const rawNum = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);

/** Reads the three answers (each may be missing) into what the call keeps. */
export function readCallMedia(rec: unknown, tr: unknown, sum: unknown): QuoCallMedia {
  const recordings = rawArr(rawObj(rec).data).map(rawObj).filter((r) => rawStr(r.url) && (rawStr(r.status) ?? 'completed') === 'completed')
    .map((r) => ({ id: rawStr(r.id), url: rawStr(r.url)!, duration: rawNum(r.duration) === null ? null : Math.round(rawNum(r.duration)!), type: rawStr(r.type) }));
  const t = rawObj(rawObj(tr).data);
  const transcript = (rawStr(t.status) ?? 'completed') === 'completed'
    ? rawArr(t.dialogue).map(rawObj).map((d) => ({ who: (rawStr(d.userId) ? 'us' : 'them') as 'us' | 'them', text: rawStr(d.content) ?? '', start: rawNum(d.start), end: rawNum(d.end) })).filter((d) => d.text)
    : [];
  const s = rawObj(rawObj(sum).data);
  const ok = (rawStr(s.status) ?? 'completed') === 'completed';
  const strings = (v: unknown) => rawArr(v).map(rawStr).filter((x): x is string => !!x);
  return { recordings, transcript, summary: ok ? strings(s.summary) : [], next_steps: ok ? strings(s.nextSteps) : [] };
}

/** One call's media from Quo (only the parts asked for). A part Quo does not have (404) is empty. */
export async function quoCallMedia(o: QuoOptions, callId: string, want: { recording: boolean; transcript: boolean; summary: boolean }): Promise<QuoCallMedia> {
  if (!/^[A-Za-z0-9_-]{4,64}$/.test(callId)) throw new QuoError('Not a call id', 400, null, true);
  const id = encodeURIComponent(callId);
  const get = async (path: string) => {
    try { return await call<unknown>(o, 'GET', path); }
    catch (e) { if (e instanceof QuoError && (e.status === 404 || e.status === 403)) return null; throw e; }
  };
  const [rec, tr, sum] = await Promise.all([want.recording ? get(`/v1/call-recordings/${id}`) : null, want.transcript ? get(`/v1/call-transcripts/${id}`) : null,
    want.summary ? get(`/v1/call-summaries/${id}`) : null]);
  return readCallMedia(rec, tr, sum);
}
