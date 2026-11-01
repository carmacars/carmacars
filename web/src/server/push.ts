import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { b64url, sendPush, vapidKeysValid, type PushOutcome } from '@/lib/push/webpush';
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

/** The public key the browser subscribes with, or null when alerts are off (the cards are then hidden). */
export async function pushPublicKey(): Promise<string | null> {
  return (await pushConfig())?.publicKey ?? null;
}

/** The signed-in person's alerts card: null hides it (no keys, switched off, or an Admin viewing as someone). */
export async function pushCard(userId: string): Promise<{ publicKey: string; state: PushState } | null> {
  const publicKey = await pushPublicKey();
  if (!publicKey) return null;
  try {
    const state = (await rpc('server_push_state', { p_user: userId }, SR)) as unknown as PushState;
    return state && state.enabled ? { publicKey, state } : null;
  } catch {
    return null;
  }
}

type Due = { id: string; endpoint: string; p256dh: string; auth: string; urgent: boolean; payload: Record<string, unknown> };

/** The push job (/api/jobs/push, from the Worker's five-minute tick and right after "Send a test alert"). */
export async function runPushJob(limit = 50): Promise<Record<string, unknown>> {
  const cfg = await pushConfig();
  if (!cfg) return { ok: true, skipped: 'VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY are not set' };
  const due = ((await rpc('server_push_due', { p_limit: limit }, SR)) as unknown as Due[]) ?? [];
  if (!due.length) return { ok: true, sent: 0 };
  const results: Array<{ id: string } & PushOutcome> = [];
  // a few at a time: each push is one request to Google's, Mozilla's or Apple's push service
  for (let i = 0; i < due.length; i += 6) {
    const part = due.slice(i, i + 6);
    const out = await Promise.all(part.map((d) => cfg.mode === 'fake' ? Promise.resolve<PushOutcome>({ outcome: 'sent' }) : sendPush(d, cfg)));
    part.forEach((d, j) => results.push({ id: d.id, ...out[j]! }));
  }
  const r = await rpc('server_push_result', { p: { results } as unknown as Json }, SR);
  return { ok: true, mode: cfg.mode, ...(r as Record<string, unknown>) };
}
