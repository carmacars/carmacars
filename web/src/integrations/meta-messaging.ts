// AI auto-replies on Meta's channels (release 36, migration 2110): the webhook's pure part. Meta posts Messenger (object
// "page"), Instagram direct messages (object "instagram") and WhatsApp (object "whatsapp_business_account") to one address,
// signed with the app secret (X-Hub-Signature-256: HMAC-SHA256 of the raw body). Here: the signature check, the incoming
// text messages read from a delivery (echoes of our own messages, reactions, media without text left out), and the
// answers sent back through the Graph API (Messenger and Instagram with the Page token, WhatsApp with its own token).
// Relative imports only: the unit tests run it in Node with a fake fetch.

export type MetaChannel = 'messenger' | 'instagram' | 'whatsapp';
export interface Incoming { channel: MetaChannel; sender: string; text: string; to: string | null; id: string | null }

const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, '0')).join('');
/** The delivery is Meta's: the signature over the raw body with the app secret, compared in constant time. */
export async function verifyMetaSignature(raw: string, header: string | null, secret: string): Promise<boolean> {
  if (!secret || !header || !/^sha256=[0-9a-f]{64}$/i.test(header)) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const want = hex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)));
  const got = header.slice(7).toLowerCase();
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return diff === 0 && got.length === want.length;
}

type J = Record<string, unknown>;
const obj = (v: unknown): J => (v && typeof v === 'object' && !Array.isArray(v) ? (v as J) : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v.trim() : null);

/** The text messages people sent, from one delivery. */
export function incomingMessages(body: unknown): Incoming[] {
  const b = obj(body), out: Incoming[] = [];
  const kind = str(b.object);
  for (const e of arr(b.entry).map(obj)) {
    if (kind === 'page' || kind === 'instagram') {
      for (const m of arr(e.messaging).map(obj)) {
        const msg = obj(m.message);
        if (msg.is_echo === true || msg.is_deleted === true) continue;
        const text = str(msg.text), sender = str(obj(m.sender).id);
        if (text && sender) out.push({ channel: kind === 'page' ? 'messenger' : 'instagram', sender, text: text.slice(0, 2000), to: str(obj(m.recipient).id), id: str(msg.mid) });
      }
    } else if (kind === 'whatsapp_business_account') {
      for (const c of arr(e.changes).map(obj)) {
        const v = obj(c.value);
        const to = str(obj(v.metadata).phone_number_id);
        for (const m of arr(v.messages).map(obj)) {
          const text = m.type === 'text' ? str(obj(m.text).body) : null, sender = str(m.from);
          if (text && sender) out.push({ channel: 'whatsapp', sender, text: text.slice(0, 2000), to, id: str(m.id) });
        }
      }
    }
  }
  return out;
}

const GRAPH = 'https://graph.facebook.com';
/** An answer back on the channel it came from. */
export async function sendMetaReply(o: { channel: MetaChannel; to: string; text: string; version: string; pageToken?: string | null; whatsappToken?: string | null; whatsappPhoneId?: string | null },
  f: typeof fetch = fetch): Promise<{ ok: boolean; error?: string }> {
  const text = o.text.slice(0, o.channel === 'whatsapp' ? 4096 : 1000);
  let url: string, token: string | null | undefined, body: J;
  if (o.channel === 'whatsapp') {
    if (!o.whatsappPhoneId) return { ok: false, error: 'no WhatsApp number id' };
    url = `${GRAPH}/${o.version}/${o.whatsappPhoneId}/messages`; token = o.whatsappToken;
    body = { messaging_product: 'whatsapp', to: o.to, type: 'text', text: { body: text, preview_url: false } };
  } else {
    url = `${GRAPH}/${o.version}/me/messages`; token = o.pageToken;
    body = { recipient: { id: o.to }, messaging_type: 'RESPONSE', message: { text } };
  }
  if (!token) return { ok: false, error: 'no token' };
  const r = await f(url, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) }).catch(() => null);
  if (!r) return { ok: false, error: 'Meta did not answer' };
  if (r.ok) return { ok: true };
  const d = (await r.json().catch(() => ({}))) as { error?: { message?: string } };
  return { ok: false, error: `Meta ${r.status}: ${d.error?.message ?? ''}`.slice(0, 200) };
}
