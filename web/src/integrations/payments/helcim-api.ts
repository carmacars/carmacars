// r50: Helcim's API (https://devdocs.helcim.com), called only from our server with the api-token header: HelcimPay.js
// checkout sessions, the Payment API (purchase, preauth, capture, refund, reverse), card transactions and customers.
// No package: fetch, so it runs in the Worker. Pure apart from the fetch it is given (unit tested with a faked Helcim:
// helcim-fake.ts). The token is never logged and never sent to the browser.

export const HELCIM_API = 'https://api.helcim.com/v2';

export class HelcimError extends Error {
  readonly status: number;
  readonly errors: string[];
  constructor(status: number, errors: string[]) {
    super(errors.length ? errors.join('; ') : `Helcim answered ${status}`);
    this.status = status;
    this.errors = errors;
  }
}

/** A card transaction as Helcim returns it (Payment API answers and GET /card-transactions/{id}). */
export interface HelcimTransaction {
  transactionId: number;
  dateCreated?: string;
  cardBatchId?: number;
  status: 'APPROVED' | 'DECLINED' | string;
  type: 'purchase' | 'preauth' | 'capture' | 'refund' | 'reverse' | 'verify' | string;
  amount: number;
  currency?: string;
  approvalCode?: string;
  cardToken?: string;
  cardNumber?: string;
  cardHolderName?: string;
  cardType?: string;
  customerCode?: string;
  invoiceNumber?: string;
  warning?: string;
}

export interface CheckoutInit {
  paymentType: 'purchase' | 'preauth' | 'verify';
  amount: number;
  currency: 'CAD';
  customerCode?: string;
  paymentMethod?: 'cc';
  confirmationScreen?: boolean;
  displayContactFields?: 0 | 1;
  language?: 'en' | 'fr';
  terminalId?: number;
}

type Json = Record<string, unknown>;

/** Dollars as Helcim takes them, from our cents: two decimals at most. */
export const dollars = (cents: number): number => Math.round(cents) / 100;
/** Our cents from Helcim's dollars. */
export const cents = (amount: unknown): number => Math.round(Number(amount ?? 0) * 100);

/** Helcim's idempotency key: 25 to 36 characters of letters, digits, - and _, kept by Helcim for 5 minutes. Ours
 *  (capture:hc_..., refund:...) are hashed to 32 hex characters, so the same call always sends the same key. */
export async function helcimKey(ours: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`carmacars:${ours}`)));
  return Array.from(d.slice(0, 16), (b) => b.toString(16).padStart(2, '0')).join('');
}

function errorsOf(body: unknown): string[] {
  const b = body as { errors?: unknown; message?: unknown } | null;
  if (!b) return [];
  if (Array.isArray(b.errors)) return b.errors.map(String);
  if (b.errors && typeof b.errors === 'object') return Object.entries(b.errors as Json).map(([k, v]) => `${k}: ${String(v)}`);
  if (typeof b.errors === 'string') return [b.errors];
  if (typeof b.message === 'string') return [b.message];
  return [];
}

export interface HelcimApi {
  initialize(r: CheckoutInit): Promise<{ checkoutToken: string; secretToken: string }>;
  purchase(r: Json, key: string): Promise<HelcimTransaction>;
  preauth(r: Json, key: string): Promise<HelcimTransaction>;
  capture(r: { preAuthTransactionId: number; amount: number; ipAddress: string; ecommerce?: boolean }, key: string): Promise<HelcimTransaction>;
  refund(r: { originalTransactionId: number; amount: number; ipAddress: string; ecommerce?: boolean }, key: string): Promise<HelcimTransaction>;
  reverse(r: { cardTransactionId: number; ipAddress: string; ecommerce?: boolean }, key: string): Promise<HelcimTransaction>;
  transaction(id: number | string): Promise<HelcimTransaction>;
  transactions(q: { dateFrom?: string; dateTo?: string; search?: string; customerCode?: string; limit?: number; page?: number }): Promise<HelcimTransaction[]>;
  createCustomer(r: { customerCode: string; contactName: string; businessName?: string; email?: string }): Promise<{ customerCode: string }>;
  connectionTest(): Promise<Json>;
}

export function helcimApi(token: string, f: typeof fetch = fetch): HelcimApi {
  if (!token) throw new Error('Missing HELCIM_API_TOKEN');
  async function call<T>(method: 'GET' | 'POST', path: string, body?: Json, idempotencyKey?: string, query?: Record<string, string>): Promise<T> {
    const q = query && Object.keys(query).length ? `?${new URLSearchParams(query).toString()}` : '';
    const headers: Record<string, string> = { accept: 'application/json', 'api-token': token };
    if (body) headers['content-type'] = 'application/json';
    if (idempotencyKey) headers['idempotency-key'] = await helcimKey(idempotencyKey);
    const res = await f(`${HELCIM_API}${path}${q}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    let parsed: unknown = null;
    try { parsed = text ? JSON.parse(text) : null; } catch { parsed = null; }
    if (!res.ok) throw new HelcimError(res.status, errorsOf(parsed));
    // a payment Helcim declined comes back as a transaction with status DECLINED (or as errors): both are kept for the caller
    return parsed as T;
  }
  const pay = (path: string) => (r: Json, key: string) => call<HelcimTransaction>('POST', path, r, key);
  return {
    initialize: (r) => call('POST', '/helcim-pay/initialize', { language: 'en', paymentMethod: 'cc', confirmationScreen: false, ...r }),
    purchase: pay('/payment/purchase'),
    preauth: pay('/payment/preauth'),
    capture: (r, key) => call('POST', '/payment/capture', r as unknown as Json, key),
    refund: (r, key) => call('POST', '/payment/refund', r as unknown as Json, key),
    reverse: (r, key) => call('POST', '/payment/reverse', r as unknown as Json, key),
    transaction: (id) => call('GET', `/card-transactions/${encodeURIComponent(String(id))}`),
    async transactions(q) {
      const query: Record<string, string> = {};
      for (const [k, v] of Object.entries(q)) if (v !== undefined && v !== null && v !== '') query[k] = String(v);
      const out = await call<unknown>('GET', '/card-transactions', undefined, undefined, query);
      return Array.isArray(out) ? (out as HelcimTransaction[]) : [];
    },
    createCustomer: (r) => call('POST', '/customers', r as unknown as Json),
    connectionTest: () => call('GET', '/connection-test')
  };
}

// ---------------------------------------------------------------- signatures

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, '0')).join('');
function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** The raw text of one top-level member of a JSON object (its value exactly as sent), or null. */
export function rawMember(json: string, name: string): string | null {
  const key = `"${name}"`;
  let i = 0, depth = 0, inStr = false;
  for (; i < json.length; i++) {
    const c = json[i]!;
    if (inStr) { if (c === '\\') i++; else if (c === '"') inStr = false; continue; }
    if (c === '"') {
      if (depth === 1 && json.startsWith(key, i)) {
        let j = i + key.length;
        while (/\s/.test(json[j] ?? '')) j++;
        if (json[j] !== ':') { inStr = true; continue; }
        j++;
        while (/\s/.test(json[j] ?? '')) j++;
        const start = j;
        let d = 0, s = false;
        for (; j < json.length; j++) {
          const ch = json[j]!;
          if (s) { if (ch === '\\') j++; else if (ch === '"') s = false; continue; }
          if (ch === '"') s = true;
          else if (ch === '{' || ch === '[') d++;
          else if (ch === '}' || ch === ']') { if (d === 0) break; d--; if (d === 0) { j++; break; } }
          else if (ch === ',' && d === 0) break;
        }
        return json.slice(start, j).trim();
      }
      inStr = true; continue;
    }
    if (c === '{' || c === '[') depth++;
    else if (c === '}' || c === ']') depth--;
  }
  return null;
}

/** JSON without the whitespace between tokens (the text inside strings is kept). */
export function compactJson(raw: string): string {
  let out = '', s = false;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i]!;
    if (s) { out += c; if (c === '\\') { out += raw[++i] ?? ''; } else if (c === '"') s = false; continue; }
    if (c === '"') { s = true; out += c; continue; }
    if (!/\s/.test(c)) out += c;
  }
  return out;
}

const asciiJson = (v: unknown) => JSON.stringify(v).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);

export async function sha256Hex(s: string): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', enc.encode(s)));
}

/** HelcimPay.js: the transaction the modal reports is Helcim's only if sha256(JSON of its data + the session's secret
 *  token) is the hash sent with it (devdocs, Validate a HelcimPay.js Payment). The data is hashed as Helcim serialized it:
 *  the raw text when we have it, else compact JSON with non-ASCII characters escaped (Helcim's PHP and Python examples),
 *  with and without escaped slashes. */
export async function verifyCheckoutHash(message: unknown, secretToken: string): Promise<{ data: Record<string, unknown> } | null> {
  if (!secretToken) return null;
  let text: string | null = typeof message === 'string' ? message : null;
  let obj: { data?: unknown; hash?: unknown } | null = null;
  try { obj = (typeof message === 'string' ? JSON.parse(message) : message) as { data?: unknown; hash?: unknown }; } catch { return null; }
  if (!obj || typeof obj !== 'object' || !obj.data || typeof obj.hash !== 'string') return null;
  // a message whose data came as a JSON string
  let data = obj.data as Record<string, unknown>;
  if (typeof obj.data === 'string') { text = null; try { data = JSON.parse(obj.data) as Record<string, unknown>; } catch { return null; } }
  const candidates = new Set<string>();
  if (typeof obj.data === 'string') candidates.add(compactJson(obj.data));
  if (text) { const raw = rawMember(text, 'data'); if (raw) candidates.add(compactJson(raw)); }
  candidates.add(JSON.stringify(data));
  candidates.add(asciiJson(data));
  candidates.add(asciiJson(data).replace(/\//g, '\\/'));
  const want = obj.hash.toLowerCase();
  for (const c of candidates) if (same(await sha256Hex(c + secretToken), want)) return { data };
  return null;
}

function b64decode(s: string): Uint8Array {
  const bin = atob(s.replace(/^whsec_/, ''));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}
function b64encode(b: ArrayBuffer): string {
  let s = '';
  for (const x of new Uint8Array(b)) s += String.fromCharCode(x);
  return btoa(s);
}

async function hmacB64(keyBytes: Uint8Array, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', keyBytes as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64encode(await crypto.subtle.sign('HMAC', key, enc.encode(message)));
}

export interface HelcimWebhookHeaders { id: string | null; timestamp: string | null; signature: string | null }

/** Helcim's webhook signature (devdocs, Webhooks): HMAC-SHA256 of "webhook-id.webhook-timestamp.body" keyed with the
 *  base64-decoded verifier token, base64; the webhook-signature header holds one or more "v1,<base64>" separated by
 *  spaces. Events older or newer than the tolerance are refused (a replay). Throws when it does not match. */
export async function verifyHelcimWebhook(rawBody: string, h: HelcimWebhookHeaders, verifierToken: string, nowSeconds = Math.floor(Date.now() / 1000), toleranceSeconds = 300): Promise<void> {
  if (!verifierToken) throw new Error('No webhook verifier token configured');
  if (!h.id || !h.timestamp || !h.signature) throw new Error('Missing webhook signature headers');
  const t = Number(h.timestamp);
  if (!Number.isFinite(t)) throw new Error('Malformed webhook timestamp');
  if (Math.abs(nowSeconds - t) > toleranceSeconds) throw new Error('Webhook timestamp outside the tolerance');
  let key: Uint8Array;
  try { key = b64decode(verifierToken); } catch { throw new Error('The verifier token is not base64'); }
  const want = await hmacB64(key, `${h.id}.${h.timestamp}.${rawBody}`);
  const sigs = h.signature.split(' ').map((p) => p.split(',')).filter((p) => p.length === 2).map((p) => p[1]!);
  if (!sigs.some((s) => same(s, want))) throw new Error('Signature does not match');
}

/** For tests and the fake: the headers Helcim would send for this body. */
export async function signHelcimWebhook(rawBody: string, verifierToken: string, id = `msg_${Date.now()}`, t = Math.floor(Date.now() / 1000)): Promise<HelcimWebhookHeaders> {
  return { id, timestamp: String(t), signature: `v1,${await hmacB64(b64decode(verifierToken), `${id}.${t}.${rawBody}`)}` };
}
