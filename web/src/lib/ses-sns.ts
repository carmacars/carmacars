// r42 (migration 2630, docs/changes/2026-11-12-r42-ses-events.md): Amazon SES bounce and complaint events, delivered by
// Amazon SNS to /api/ses/events. Pure (Web Crypto and fetch only, no AWS SDK) so the route and the unit tests share it.
//   - verifySns: checks an SNS message's signature (SignatureVersion 1 = RSA SHA-1, 2 = RSA SHA-256) the way AWS documents:
//     the certificate comes only from https://sns.<region>.amazonaws.com/ (path ending .pem), its subject must be SNS's,
//     it must be in date, and the signed string is rebuilt from the fields AWS names for the message type
//   - sesEvents: the permanent bounces and complaints of a notification (configuration-set events and the older
//     notificationType form), one entry per address
// Nothing in the message is believed before its signature is checked.

export interface SnsMessage {
  Type: string; MessageId: string; TopicArn: string; Message: string; Timestamp: string;
  SignatureVersion: string; Signature: string; SigningCertURL: string;
  Subject?: string; Token?: string; SubscribeURL?: string; UnsubscribeURL?: string;
}

const SNS_HOST = /^sns\.[a-z0-9-]{4,30}\.amazonaws\.com$/;

/** A URL that is https, on sns.<region>.amazonaws.com, the default port, no credentials. */
export function isSnsUrl(raw: unknown): raw is string {
  if (typeof raw !== 'string' || raw.length > 2048) return false;
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  return u.protocol === 'https:' && SNS_HOST.test(u.hostname) && u.port === '' && !u.username && !u.password;
}
export const isSnsCertUrl = (raw: unknown): raw is string => isSnsUrl(raw) && new URL(raw).pathname.endsWith('.pem');

// The fields that are signed, in order (AWS docs, "Verifying the signatures of Amazon SNS messages")
const SIGNED: Record<string, string[]> = {
  Notification: ['Message', 'MessageId', 'Subject', 'Timestamp', 'TopicArn', 'Type'],
  SubscriptionConfirmation: ['Message', 'MessageId', 'SubscribeURL', 'Timestamp', 'Token', 'TopicArn', 'Type'],
  UnsubscribeConfirmation: ['Message', 'MessageId', 'SubscribeURL', 'Timestamp', 'Token', 'TopicArn', 'Type'],
};
export function stringToSign(m: SnsMessage): string | null {
  const names = SIGNED[m.Type];
  if (!names) return null;
  const rec = m as unknown as Record<string, unknown>;
  let s = '';
  for (const n of names) {
    const v = rec[n];
    if (v === undefined || v === null) { if (n === 'Subject') continue; return null; }
    if (typeof v !== 'string') return null;
    s += `${n}\n${v}\n`;
  }
  return s;
}

// ---- a minimal DER reader: just enough to take the public key and validity out of an X.509 certificate
interface Tlv { tag: number; start: number; end: number; hdr: number }
function tlv(b: Uint8Array, at: number): Tlv {
  const tag = b[at]!; let len = b[at + 1]!; let p = at + 2;
  if (len & 0x80) { const n = len & 0x7f; if (n < 1 || n > 4) throw new Error('der length'); len = 0; for (let i = 0; i < n; i++) len = len * 256 + b[p++]!; }
  if (p + len > b.length) throw new Error('der overrun');
  return { tag, start: p, end: p + len, hdr: p - at };
}
function children(b: Uint8Array, t: Tlv): Tlv[] { const out: Tlv[] = []; let p = t.start; while (p < t.end) { const c = tlv(b, p); out.push(c); p = c.end; } return out; }
function derTime(b: Uint8Array, t: Tlv): number {
  const s = new TextDecoder().decode(b.slice(t.start, t.end));
  const m = t.tag === 0x17 ? /^(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)?Z$/.exec(s) : /^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)?Z$/.exec(s);
  if (!m) throw new Error('der time');
  const y = t.tag === 0x17 ? (Number(m[1]) >= 50 ? 1900 : 2000) + Number(m[1]) : Number(m[1]);
  return Date.UTC(y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6] ?? 0));
}
export function pemToDer(pem: string): Uint8Array<ArrayBuffer> | null {
  const m = /-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----/.exec(pem);
  if (!m) return null;
  try { return Uint8Array.from(atob(m[1]!.replace(/\s+/g, '')), (c) => c.charCodeAt(0)); } catch { return null; }
}
/** The SPKI (for crypto.subtle.importKey) and the validity of a DER certificate; the subject must name SNS. */
export function certInfo(der: Uint8Array): { spki: Uint8Array<ArrayBuffer>; notBefore: number; notAfter: number; snsSubject: boolean } {
  const cert = tlv(der, 0);
  const tbs = children(der, cert)[0]!;
  const f = children(der, tbs);
  const i = f[0]!.tag === 0xa0 ? 1 : 0; // [0] version is optional
  const validity = children(der, f[i + 3]!);
  const subject = f[i + 4]!;
  const spki = f[i + 5]!;
  const subjectText = new TextDecoder('latin1').decode(der.slice(subject.start, subject.end));
  return {
    spki: der.slice(spki.start - spki.hdr, spki.end),
    notBefore: derTime(der, validity[0]!), notAfter: derTime(der, validity[1]!),
    snsSubject: subjectText.includes('sns.amazonaws.com'),
  };
}

export type CertFetch = (url: string) => Promise<string>;
const certCache = new Map<string, { key: CryptoKey; until: number }>();
/** For the tests. */
export const clearCertCache = () => certCache.clear();
const defaultCertFetch: CertFetch = async (url) => {
  const r = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(5000) });
  if (!r.ok) throw new Error(`certificate ${r.status}`);
  const t = await r.text();
  if (t.length > 20_000) throw new Error('certificate too large');
  return t;
};

async function signingKey(url: string, hash: 'SHA-1' | 'SHA-256', fetchCert: CertFetch, now: number): Promise<CryptoKey> {
  const k = `${hash} ${url}`;
  const hit = certCache.get(k);
  if (hit && hit.until > now) return hit.key;
  const der = pemToDer(await fetchCert(url));
  if (!der) throw new Error('not a certificate');
  const info = certInfo(der);
  if (!info.snsSubject) throw new Error('certificate is not Amazon SNS\'s');
  if (now < info.notBefore || now > info.notAfter) throw new Error('certificate not in date');
  const key = await crypto.subtle.importKey('spki', info.spki, { name: 'RSASSA-PKCS1-v1_5', hash }, false, ['verify']);
  certCache.set(k, { key, until: Math.min(info.notAfter, now + 3_600_000) });
  return key;
}

export interface VerifyOptions { fetchCert?: CertFetch; now?: number; topicArn?: string }
export type Verified = { ok: true; message: SnsMessage } | { ok: false; reason: string };

/** Parse and verify an SNS HTTP body. Only a message whose signature checks out is returned. */
export async function verifySns(raw: string, opts: VerifyOptions = {}): Promise<Verified> {
  let m: SnsMessage;
  try { m = JSON.parse(raw) as SnsMessage; } catch { return { ok: false, reason: 'not json' }; }
  if (!m || typeof m !== 'object') return { ok: false, reason: 'not an object' };
  const hash = m.SignatureVersion === '1' ? 'SHA-1' : m.SignatureVersion === '2' ? 'SHA-256' : null;
  if (!hash) return { ok: false, reason: 'unknown signature version' };
  if (!isSnsCertUrl(m.SigningCertURL)) return { ok: false, reason: 'signing certificate URL is not Amazon SNS\'s' };
  const sts = stringToSign(m);
  if (sts === null || typeof m.Signature !== 'string') return { ok: false, reason: 'missing fields' };
  if (opts.topicArn && m.TopicArn !== opts.topicArn) return { ok: false, reason: 'unexpected topic' };
  try {
    const sig = Uint8Array.from(atob(m.Signature), (c) => c.charCodeAt(0));
    const key = await signingKey(m.SigningCertURL, hash, opts.fetchCert ?? defaultCertFetch, opts.now ?? Date.now());
    const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, sig, new TextEncoder().encode(sts));
    return ok ? { ok: true, message: m } : { ok: false, reason: 'bad signature' };
  } catch (e) {
    return { ok: false, reason: e instanceof Error ? e.message.slice(0, 120) : 'verify failed' };
  }
}

export interface SesSuppression { messageId: string | null; kind: 'bounce' | 'complaint'; email: string; detail: string }

/** The addresses to suppress from an SES event (the Message of a verified Notification): permanent bounces and complaints. */
export function sesEvents(message: string): SesSuppression[] {
  let e: Record<string, unknown>;
  try { e = JSON.parse(message) as Record<string, unknown>; } catch { return []; }
  const type = String(e.eventType ?? e.notificationType ?? '');
  const mail = (e.mail ?? {}) as { messageId?: unknown };
  const messageId = typeof mail.messageId === 'string' ? mail.messageId : null;
  const out: SesSuppression[] = [];
  const addr = (v: unknown) => (typeof v === 'string' ? v.trim().toLowerCase() : '');
  if (type === 'Bounce') {
    const b = (e.bounce ?? {}) as { bounceType?: unknown; bounceSubType?: unknown; bouncedRecipients?: unknown };
    if (b.bounceType !== 'Permanent' || !Array.isArray(b.bouncedRecipients)) return [];
    for (const r of b.bouncedRecipients as Array<{ emailAddress?: unknown; diagnosticCode?: unknown }>) {
      const email = addr(r?.emailAddress);
      if (email) out.push({ messageId, kind: 'bounce', email, detail: `Permanent/${String(b.bounceSubType ?? 'General')}${typeof r.diagnosticCode === 'string' ? ': ' + r.diagnosticCode : ''}`.slice(0, 300) });
    }
  } else if (type === 'Complaint') {
    const c = (e.complaint ?? {}) as { complainedRecipients?: unknown; complaintFeedbackType?: unknown };
    if (!Array.isArray(c.complainedRecipients)) return [];
    for (const r of c.complainedRecipients as Array<{ emailAddress?: unknown }>) {
      const email = addr(r?.emailAddress);
      if (email) out.push({ messageId, kind: 'complaint', email, detail: `Complaint${typeof c.complaintFeedbackType === 'string' ? ': ' + c.complaintFeedbackType : ''}`.slice(0, 300) });
    }
  }
  return out.filter((x) => /^[^\s@]+@[^\s@]+$/.test(x.email));
}
