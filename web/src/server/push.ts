import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { b64url, sendPush, vapidKeysValid, type PushOutcome } from '@/lib/push/webpush';
import { parseFcmAccount, sendFcm, type FcmAccount } from '@/lib/push/fcm';
import type { PushState } from '@/features/push/topics';

// Phone and browser alerts (migration 0300). On only when the Worker has the VAPID keys (the vault secrets
// deploy_vapid_public_key and deploy_vapid_private_key, exported by scripts/deploy/supabase.sh secrets as
// VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY); without them every alerts card is hidden and the job does nothing.
// Locally and in the tests PUSH_PROVIDER=fake turns the cards on with a key pair made in memory for this process (never
// stored, never committed) and "sends" by recording the alert as sent.
const SR = { role: 'service_role' as const };

export interface PushConfig { mode: 'webpush' | 'fake'; publicKey: string; privateKey: string; subject: string }

let fakeKeys: Promise<{ publicKey: string; privateKey: string }> | null = null;
async function makeFakeKeys() {
  const k = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  return { publicKey: b64url(await crypto.subtle.exportKey('raw', k.publicKey)), privateKey: (await crypto.subtle.exportKey('jwk', k.privateKey)).d! };
}

export async function pushConfig(): Promise<PushConfig | null> {
  const e = env();
  const subject = e.VAPID_SUBJECT || e.NEXT_PUBLIC_APP_URL;
  if (vapidKeysValid(e.VAPID_PUBLIC_KEY, e.VAPID_PRIVATE_KEY)) return { mode: 'webpush', publicKey: e.VAPID_PUBLIC_KEY!, privateKey: e.VAPID_PRIVATE_KEY!, subject };
  if (e.PUSH_PROVIDER === 'fake' && e.APP_ENV !== 'production') return { mode: 'fake', ...(await (fakeKeys ??= makeFakeKeys())), subject };
  return null;
}

// The store app (migration 0390): Firebase Cloud Messaging with the service account in FCM_SERVICE_ACCOUNT (the vault
// secret deploy_fcm_service_account). Without it the app's alerts card is hidden and app devices are not sent to; the
// browser alerts above work on their own. PUSH_PROVIDER=fake turns the app's card on too (local work and tests).
export interface NativePushConfig { mode: 'fcm' | 'fake'; account: FcmAccount | null }

export function nativePushConfig(): NativePushConfig | null {
  const e = env();
  const account = parseFcmAccount(e.FCM_SERVICE_ACCOUNT);
  if (account) return { mode: 'fcm', account };
  if (e.PUSH_PROVIDER === 'fake' && e.APP_ENV !== 'production') return { mode: 'fake', account: null };
  return null;
}

/** The public key the browser subscribes with, or null when alerts are off (the cards are then hidden). */
export async function pushPublicKey(): Promise<string | null> {
  return (await pushConfig())?.publicKey ?? null;
}

/** The signed-in person's alerts card: null hides it (no keys, switched off, or an Admin viewing as someone). In the
 *  store app the card needs the Firebase service account; in a browser, the VAPID keys. */
export async function pushCard(userId: string, app = false): Promise<{ publicKey: string | null; native: boolean; state: PushState } | null> {
  const native = app && nativePushConfig() !== null;
  const publicKey = app ? null : await pushPublicKey();
  if (!publicKey && !native) return null;
  try {
    const state = (await rpc('server_push_state', { p_user: userId }, SR)) as unknown as PushState;
    return state && state.enabled ? { publicKey, native, state } : null;
  } catch {
    return null;
  }
}

type Due = { id: string; kind: 'web' | 'fcm'; platform: string | null; endpoint: string | null; token: string | null; p256dh: string | null; auth: string | null;
  urgent: boolean; payload: Record<string, unknown> };

/** The kinds of device this Worker can send to now: browsers with the VAPID keys, the app with the Firebase account. */
export async function pushKinds(): Promise<Array<'web' | 'fcm'>> {
  return [...((await pushConfig()) ? ['web' as const] : []), ...(nativePushConfig() ? ['fcm' as const] : [])];
}

/** The push job (/api/jobs/push, from the Worker's five-minute tick and right after "Send a test alert"). Claims only
 *  the alerts of the kinds it can send (migration 0390): an app device waits while the Firebase account is missing. */
export async function runPushJob(limit = 50): Promise<Record<string, unknown>> {
  const [web, native] = [await pushConfig(), nativePushConfig()];
  const kinds = [...(web ? ['web'] : []), ...(native ? ['fcm'] : [])];
  if (!kinds.length) return { ok: true, skipped: 'neither the VAPID keys nor the Firebase service account is set' };
  const due = ((await rpc('server_push_due', { p_limit: limit, p_kinds: kinds }, SR)) as unknown as Due[]) ?? [];
  if (!due.length) return { ok: true, sent: 0 };
  const one = (d: Due): Promise<PushOutcome> => {
    if (d.kind === 'fcm') {
      if (!native || !d.token) return Promise.resolve({ outcome: 'retry', error: 'no Firebase account' });
      return native.mode === 'fake' || !native.account ? Promise.resolve({ outcome: 'sent' }) : sendFcm({ token: d.token, urgent: d.urgent, platform: d.platform, payload: d.payload }, native.account);
    }
    if (!web || !d.endpoint || !d.p256dh || !d.auth) return Promise.resolve({ outcome: 'retry', error: 'no VAPID keys' });
    return web.mode === 'fake' ? Promise.resolve({ outcome: 'sent' }) : sendPush({ endpoint: d.endpoint, p256dh: d.p256dh, auth: d.auth, urgent: d.urgent, payload: d.payload }, web);
  };
  const results: Array<{ id: string } & PushOutcome> = [];
  // a few at a time: each push is one request to Google's, Mozilla's or Apple's push service, or to Firebase
  for (let i = 0; i < due.length; i += 6) {
    const part = due.slice(i, i + 6);
    const out = await Promise.all(part.map(one));
    part.forEach((d, j) => results.push({ id: d.id, ...out[j]! }));
  }
  const r = await rpc('server_push_result', { p: { results } as unknown as Json }, SR);
  return { ok: true, kinds, ...(r as Record<string, unknown>) };
}
