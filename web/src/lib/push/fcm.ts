// Phone alerts in the App Store and Google Play app (migration 0390): Firebase Cloud Messaging, HTTP v1. One Firebase
// project sends to both platforms (Android directly, iPhone through APNs with the key the owner uploads to Firebase).
// The Worker signs in as the project's service account (a JWT signed RS256 with WebCrypto, exchanged for a one-hour
// access token, kept for the run) and posts one message per device. The service account JSON lives only in the
// Supabase vault (deploy_fcm_service_account) and the Worker's secrets (FCM_SERVICE_ACCOUNT); never in the repository.
// No imports: the Worker, Node and the unit tests share it.

export type FcmOutcome = { outcome: 'sent' | 'gone' | 'refused' | 'retry'; error?: string };
export interface FcmAccount { project_id: string; client_email: string; private_key: string; private_key_id?: string; token_uri: string }
export interface FcmDue { token: string; urgent?: boolean; platform?: string | null; payload: { title?: unknown; body?: unknown; url?: unknown; tag?: unknown; code?: unknown } }

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const TOKEN_URI = 'https://oauth2.googleapis.com/token';

function b64url(bytes: ArrayBuffer | Uint8Array | string): string {
  const u = typeof bytes === 'string' ? new TextEncoder().encode(bytes) : bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = '';
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** The service account, from its JSON (as downloaded from Firebase) or that JSON in base64. Null when unusable. */
export function parseFcmAccount(raw: string | null | undefined): FcmAccount | null {
  const s = (raw ?? '').trim();
  if (!s) return null;
  let j: Record<string, unknown>;
  try {
    j = JSON.parse(s.startsWith('{') ? s : atob(s)) as Record<string, unknown>;
  } catch { return null; }
  const str = (k: string) => (typeof j[k] === 'string' ? (j[k] as string).trim() : '');
  const acc = { project_id: str('project_id'), client_email: str('client_email'), private_key: str('private_key'), private_key_id: str('private_key_id') || undefined,
    token_uri: str('token_uri') || TOKEN_URI };
  if (!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(acc.project_id) || !/^[^@\s]+@[^@\s]+\.gserviceaccount\.com$/.test(acc.client_email)
    || !/-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----/.test(acc.private_key) || !/^https:\/\/[^\s]+$/.test(acc.token_uri)) return null;
  return acc;
}

function pkcs8(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\\n/g, '').replace(/\s+/g, '');
  const bin = atob(body);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** The signed request for an access token (RFC 7523 JWT bearer), valid one hour. */
export async function fcmAssertion(acc: FcmAccount, now = Date.now()): Promise<string> {
  const iat = Math.floor(now / 1000);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT', ...(acc.private_key_id ? { kid: acc.private_key_id } : {}) }));
  const claims = b64url(JSON.stringify({ iss: acc.client_email, scope: SCOPE, aud: acc.token_uri, iat, exp: iat + 3600 }));
  const key = await crypto.subtle.importKey('pkcs8', pkcs8(acc.private_key), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${claims}`));
  return `${head}.${claims}.${b64url(sig)}`;
}

let cached: { email: string; token: string; until: number } | null = null;

/** A one-hour access token for the FCM API, reused while it has more than a minute left. */
export async function fcmAccessToken(acc: FcmAccount, f: typeof fetch = fetch, now = Date.now()): Promise<string> {
  if (cached && cached.email === acc.client_email && cached.until > now + 60_000) return cached.token;
  const r = await f(acc.token_uri, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${await fcmAssertion(acc, now)}`,
    signal: AbortSignal.timeout(10_000)
  });
  const j = (await r.json().catch(() => null)) as { access_token?: string; expires_in?: number; error?: string } | null;
  if (!r.ok || !j?.access_token) throw new Error(`Firebase sign-in refused (${r.status}${j?.error ? ` ${j.error}` : ''})`);
  cached = { email: acc.client_email, token: j.access_token, until: now + Math.max(60, Math.min(j.expires_in ?? 3600, 3600)) * 1000 };
  return j.access_token;
}

/** Forget the access token (tests, and a run after the service account changed). */
export function resetFcmToken(): void { cached = null; }

const text = (v: unknown, n: number) => (typeof v === 'string' ? v : v == null ? '' : String(v)).slice(0, n);

/** The FCM v1 message for one device: a visible alert, its page in data.url (the app opens it on a tap). */
export function fcmMessage(d: FcmDue): Record<string, unknown> {
  const p = d.payload ?? {};
  const tag = text(p.tag, 64);
  const data: Record<string, string> = { url: text(p.url, 500) || '/', tag, code: text(p.code, 80) };
  return {
    message: {
      token: d.token,
      notification: { title: text(p.title, 120) || 'CarmaCars', ...(text(p.body, 240) ? { body: text(p.body, 240) } : {}) },
      data,
      // user-visible alerts go at high priority on both platforms (Firebase's guidance); an urgent one also cuts through
      android: { priority: 'HIGH', ttl: d.urgent ? '3600s' : '86400s',
        notification: { channel_id: 'alerts', color: '#d0111b', ...(tag ? { tag } : {}), default_sound: true } },
      apns: { headers: { 'apns-priority': '10', 'apns-push-type': 'alert', ...(tag ? { 'apns-collapse-id': tag } : {}) },
        payload: { aps: { sound: 'default', ...(d.urgent ? { 'interruption-level': 'time-sensitive' } : {}) } } }
    }
  };
}

/** What Firebase's answer means for the device (0300's outcomes: gone deletes it, refused counts, retry tries again). */
export function fcmOutcomeOf(status: number, body?: unknown): FcmOutcome {
  if (status >= 200 && status < 300) return { outcome: 'sent' };
  const e = (body as { error?: { status?: string; message?: string; details?: Array<{ errorCode?: string }> } } | null)?.error;
  const code = e?.details?.find((x) => x?.errorCode)?.errorCode ?? e?.status ?? '';
  const error = `${status} ${code}${e?.message ? `: ${e.message}` : ''}`.slice(0, 300);
  // the app was removed or its token replaced, or the token belongs to another Firebase project
  if (status === 404 || code === 'UNREGISTERED' || code === 'SENDER_ID_MISMATCH') return { outcome: 'gone', error };
  // a token Firebase cannot read: counted (three in a row end the device)
  if (status === 400) return { outcome: 'refused', error };
  // our side (the service account, the APNs key in Firebase), Firebase's quota or an outage: again in 5 minutes
  return { outcome: 'retry', error };
}

export async function sendFcm(d: FcmDue, acc: FcmAccount, f: typeof fetch = fetch): Promise<FcmOutcome> {
  try {
    const token = await fcmAccessToken(acc, f);
    const r = await f(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(acc.project_id)}/messages:send`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(fcmMessage(d)), signal: AbortSignal.timeout(10_000)
    });
    return fcmOutcomeOf(r.status, await r.json().catch(() => null));
  } catch (e) {
    return { outcome: 'retry', error: (e instanceof Error ? e.message : 'network').slice(0, 300) };
  }
}
