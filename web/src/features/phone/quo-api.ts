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
