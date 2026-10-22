// Quo (formerly OpenPhone) webhooks, migration 0085: the signature check and the payload reader. No imports, so it
// runs in the Worker, in Node and in the unit tests (webhook.test.ts, with the sample payloads of Quo's documentation).
//
// Two signature schemes exist (Quo's docs, "Validate webhook signatures" and "Migrate from legacy webhooks"):
//   current (webhooks created with POST /webhooks and Quo-Api-Version 2026-03-30, the ones our deploy creates):
//     headers webhook-id, webhook-timestamp (Unix seconds), webhook-signature ("v1,<base64>" entries, space separated);
//     HMAC-SHA256 over "<id>.<timestamp>.<raw body>" with the key "whsec_<base64>" (prefix removed, base64 decoded).
//   legacy (webhooks made in the Quo app or the old /v1/webhooks endpoints):
//     header openphone-signature "hmac;1;<timestamp>;<base64>" (comma separated if several); HMAC-SHA256 over
//     "<timestamp>.<raw body>" with the base64-decoded signing secret.
// Both fail closed: no secret, no header, a timestamp outside the tolerance or no matching signature is refused.

export const TOLERANCE_SECONDS = 300;

const enc = new TextEncoder();

function b64ToBytes(b64: string): Uint8Array {
  const s = atob(b64.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, ''));
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
function bytesToB64(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s);
}
function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function hmac(key: Uint8Array, data: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', key as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return bytesToB64(new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(data))));
}
function keyBytes(secret: string): Uint8Array | null {
  try { const b = b64ToBytes(secret.trim().replace(/^whsec_/, '')); return b.length ? b : null; } catch { return null; }
}

export type HeaderGet = (name: string) => string | null | undefined;
export interface Verified { ok: boolean; scheme?: 'current' | 'legacy'; id?: string; reason?: string }

/** Checks a delivery against one or more secrets (a rotated key and the previous one). */
export async function verifyQuoSignature(raw: string, header: HeaderGet, secrets: Array<string | undefined | null>, nowSeconds = Math.floor(Date.now() / 1000)): Promise<Verified> {
  const keys = secrets.filter((s): s is string => !!s && !!s.trim()).map(keyBytes).filter((k): k is Uint8Array => !!k);
  if (!keys.length) return { ok: false, reason: 'no secret' };
  const id = header('webhook-id'), ts = header('webhook-timestamp'), sig = header('webhook-signature');
  if (id && ts && sig) {
    const t = Number(ts);
    if (!Number.isFinite(t) || Math.abs(nowSeconds - t) > TOLERANCE_SECONDS) return { ok: false, reason: 'timestamp' };
    const given = sig.split(' ').map((e) => e.split(',')).filter(([v, s]) => v === 'v1' && !!s).map(([, s]) => s!);
    for (const k of keys) {
      const want = await hmac(k, `${id}.${ts}.${raw}`);
      if (given.some((g) => sameText(g, want))) return { ok: true, scheme: 'current', id };
    }
    return { ok: false, reason: 'signature' };
  }
  const legacy = header('openphone-signature');
  if (legacy) {
    for (const part of legacy.split(',')) {
      const [scheme, version, stamp, s] = part.trim().split(';');
      if (scheme !== 'hmac' || version !== '1' || !stamp || !s) continue;
      const n = Number(stamp);
      const secs = n > 1e11 ? Math.floor(n / 1000) : n;
      if (!Number.isFinite(secs) || Math.abs(nowSeconds - secs) > TOLERANCE_SECONDS) return { ok: false, reason: 'timestamp' };
      for (const k of keys) {
        if (sameText(s, await hmac(k, `${stamp}.${raw}`))) return { ok: true, scheme: 'legacy' };
      }
    }
    return { ok: false, reason: 'signature' };
  }
  return { ok: false, reason: 'no signature header' };
}

/** Signs a body the current way (the tests and the e2e mock send signed deliveries). */
export async function signQuo(raw: string, secret: string, id: string, ts = Math.floor(Date.now() / 1000)): Promise<Record<string, string>> {
  const k = keyBytes(secret);
  if (!k) throw new Error('bad secret');
  return { 'webhook-id': id, 'webhook-timestamp': String(ts), 'webhook-signature': `v1,${await hmac(k, `${id}.${ts}.${raw}`)}` };
}
export async function signQuoLegacy(raw: string, secret: string, tsMs = Date.now()): Promise<Record<string, string>> {
  const k = keyBytes(secret);
  if (!k) throw new Error('bad secret');
  return { 'openphone-signature': `hmac;1;${tsMs};${await hmac(k, `${tsMs}.${raw}`)}` };
}

// ---------------------------------------------------------------- the payload
/** One event in the shape the database takes (app.server_phone_event). */
export interface PhoneEvent {
  event_id: string | null;
  type: string;
  quo_id: string | null;
  call_id: string | null;
  direction: 'in' | 'out';
  their_number: string | null;
  phone_number_id: string | null;
  conversation_id: string | null;
  user_id: string | null;
  text: string | null;
  status: string | null;
  error_code: string | null;
  media: Array<{ url: string; type: string | null }>;
  at: string | null;
  answered_at: string | null;
  completed_at: string | null;
  duration: number | null;
  missed: boolean;
  recordings: Array<{ id: string | null; url: string; duration: number | null; type: string | null }>;
  summary: string[];
  next_steps: string[];
  transcript: Array<{ who: 'us' | 'them'; text: string; start: number | null; end: number | null }>;
  voicemail_text: string | null;
  voicemail_url: string | null;
}

export const HANDLED = new Set(['message.received', 'message.delivered', 'message.failed', 'message.undelivered', 'call.ringing', 'call.answered',
  'call.completed', 'call.missed', 'call.forwarded', 'call.recording.completed', 'call.summary.completed', 'call.transcript.completed', 'call.voicemail.completed']);
/** The events our webhook subscribes to (scripts/deploy/quo.mjs reads this list from here). */
export const EVENTS = [...HANDLED];

// call statuses that mean nobody answered an incoming call (legacy: "no-answer", "missed"; current: "missed", "unanswered")
const MISSED = new Set(['missed', 'no-answer', 'no_answer', 'unanswered', 'abandoned', 'busy', 'canceled', 'cancelled']);

type J = Record<string, unknown>;
const obj = (v: unknown): J => (v && typeof v === 'object' && !Array.isArray(v) ? (v as J) : {});
const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : typeof v === 'number' ? String(v) : null);
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v.trim() && Number.isFinite(Number(v)) ? Number(v) : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const strs = (v: unknown): string[] => arr(v).map(str).filter((x): x is string => !!x);
const e164 = (v: unknown): string | null => { const s = str(v); if (!s) return null; const d = s.replace(/[^0-9]/g, ''); if (/^[2-9]\d{9}$/.test(d)) return `+1${d}`; if (/^1[2-9]\d{9}$/.test(d)) return `+${d}`; return s.startsWith('+') && d.length >= 8 && d.length <= 15 ? `+${d}` : null; };

/** Reads one delivery (current envelope data.resource/data.context, or legacy data.object). Null when it is not an event. */
export function parseQuoEvent(body: unknown, deliveryId?: string | null, ourNumber?: string | null): PhoneEvent | null {
  const b = obj(body);
  const type = str(b.type);
  if (!type) return null;
  const data = obj(b.data);
  const legacy = 'object' in data && !('resource' in data);
  const r = legacy ? obj(data.object) : obj(data.resource);
  const c = legacy ? {} : obj(data.context);
  const ours = e164(ourNumber);
  const isCall = type.startsWith('call.');
  const callId = isCall ? str(r.callId) ?? str(r.id) : null;
  const quoId = isCall ? (type === 'call.voicemail.completed' ? str(r.callId) ?? str(r.id) : callId) : str(r.id);
  let dir: 'in' | 'out' = str(r.direction) === 'outgoing' ? 'out' : 'in';
  if (type === 'call.missed') dir = 'in';
  // the outside party
  let their: string | null = null;
  if (!isCall) {
    const sender = e164(c.senderIdentifier) ?? e164(r.from);
    const recips = [...strs(c.recipientIdentifiers), ...(Array.isArray(r.to) ? strs(r.to) : [str(r.to)].filter((x): x is string => !!x))].map(e164).filter((x): x is string => !!x);
    if (!str(r.direction)) dir = sender && ours && sender === ours ? 'out' : 'in';
    their = dir === 'in' ? sender : recips.find((x) => x !== ours) ?? null;
  } else {
    const parts = obj(c.participants);
    const ext = strs(parts.external).map(e164).filter((x): x is string => !!x);
    their = ext[0] ?? null;
    if (!their) {
      // legacy call objects (and voicemails) carry from and to
      const from = e164(r.from), to = e164(Array.isArray(r.to) ? r.to[0] : r.to);
      their = dir === 'in' ? from : to;
      if (!their) their = [from, to].find((x) => x && x !== ours) ?? null;
      if (!their) their = strs(r.participants).map(e164).find((x) => x && x !== ours) ?? null;
    }
  }
  const status = str(r.status) ?? (type === 'call.missed' ? 'missed' : null);
  const answeredAt = str(r.answeredAt);
  const missed = isCall && dir === 'in' && (type === 'call.missed' || (type === 'call.completed' && ((status !== null && MISSED.has(status)) || (!answeredAt && status !== 'answered' && status !== 'completed'))));
  const recordings = [...arr(r.recordings), ...(legacy ? arr(r.media) : [])].map(obj).map((x) => ({ id: str(x.id), url: str(x.url) ?? '', duration: num(x.duration), type: str(x.type) })).filter((x) => x.url);
  const dialogue = arr(r.dialogue).map(obj).map((d) => ({ who: (str(d.userId) ? 'us' : (e164(d.identifier) && e164(d.identifier) === ours) ? 'us' : 'them') as 'us' | 'them', text: str(d.content) ?? '', start: num(d.start), end: num(d.end) })).filter((d) => d.text);
  const vm = obj(r.voicemail);
  return {
    event_id: str(deliveryId) ?? str(b.id),
    type,
    quo_id: quoId,
    call_id: callId,
    direction: dir,
    their_number: their,
    phone_number_id: str(c.phoneNumberId) ?? str(r.phoneNumberId),
    conversation_id: str(c.conversationId) ?? str(r.conversationId),
    user_id: str(c.userId) ?? str(r.userId),
    text: isCall ? null : str(r.text) ?? str(r.body),
    status,
    error_code: str(r.errorCode),
    media: isCall ? [] : arr(r.media).map(obj).map((m) => ({ url: str(m.url) ?? '', type: str(m.type) })).filter((m) => m.url),
    at: str(r.createdAt),
    answered_at: answeredAt,
    completed_at: str(r.completedAt),
    duration: num(r.duration),
    missed,
    recordings,
    summary: strs(r.summary),
    next_steps: strs(r.nextSteps),
    transcript: type === 'call.transcript.completed' ? dialogue : [],
    voicemail_text: type === 'call.voicemail.completed' ? str(r.transcript) : str(vm.transcript),
    voicemail_url: type === 'call.voicemail.completed' ? str(r.recordingUrl) : str(vm.url)
  };
}

/** A transcript as plain lines for the AI summary prompt. */
export function transcriptText(t: PhoneEvent['transcript'] | null | undefined, max = 6000): string {
  return (t ?? []).map((d) => `${d.who === 'us' ? 'CarmaCars' : 'Caller'}: ${d.text}`).join('\n').slice(0, max);
}
