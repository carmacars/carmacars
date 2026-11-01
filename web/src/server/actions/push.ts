'use server';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { TOPICS, type PushState, type Topic } from '@/features/push/topics';
import { nativePushConfig, pushConfig, runPushJob } from '@/server/push';

// Phone and browser alerts (migration 0300): the signed-in person turns alerts on or off for this device, chooses the
// topics and sends a test. The database keeps the device (its push address and keys) and decides what alerts it.
const SR = { role: 'service_role' as const };
const PORTALS = ['renter', 'owner', 'investor', 'staff', 'field', 'admin'] as const;

// a browser needs the VAPID keys, the store app the Firebase service account (0390); either is enough for the topics
async function signedIn(kind: 'web' | 'fcm' | 'any' = 'any') {
  const on = kind === 'web' ? !!(await pushConfig()) : kind === 'fcm' ? nativePushConfig() !== null : !!(await pushConfig()) || nativePushConfig() !== null;
  if (!on) return { error: { ok: false as const, code: 'off', message: 'Alerts are not available yet.' } };
  const user = await (await auth()).currentUser();
  return user ? { user } : { error: { ok: false as const, code: 'auth', message: 'Sign in first.' } };
}
const refused = (e: unknown) => ({ ok: false as const, code: 'refused', message: e instanceof DbError ? e.message : 'Not saved. Try again.' });

export interface DeviceSubscription { endpoint: string; p256dh: string; auth: string; portal?: string; device?: string }
/** The store app's device (0390): its Firebase token instead of a browser's address and keys. */
export interface AppSubscription { kind: 'fcm'; token: string; platform: 'ios' | 'android'; portal?: string; device?: string }

export async function subscribePush(sub: DeviceSubscription | AppSubscription): Promise<ActionResult<PushState>> {
  const app = (sub as AppSubscription)?.kind === 'fcm';
  const s = await signedIn(app ? 'fcm' : 'web');
  if (s.error) return s.error;
  const portal = PORTALS.includes(sub?.portal as (typeof PORTALS)[number]) ? sub.portal : undefined;
  const device = typeof sub?.device === 'string' ? sub.device.slice(0, 60) : undefined;
  if (app) {
    const a = sub as AppSubscription;
    if (typeof a.token !== 'string' || !a.token) return { ok: false, code: 'invalid', message: 'This phone gave no push address.' };
    try {
      const p = { kind: 'fcm', token: a.token, platform: a.platform === 'ios' || a.platform === 'android' ? a.platform : null, portal, device };
      return { ok: true, data: (await rpc('server_push_subscribe', { p_user: s.user.id, p: p as unknown as Json }, SR)) as unknown as PushState };
    } catch (e) { return refused(e); }
  }
  const w = sub as DeviceSubscription;
  if (typeof w?.endpoint !== 'string' || typeof w.p256dh !== 'string' || typeof w.auth !== 'string') return { ok: false, code: 'invalid', message: 'This browser gave no push address.' };
  try {
    const p = { endpoint: w.endpoint, p256dh: w.p256dh, auth: w.auth, portal, device };
    return { ok: true, data: (await rpc('server_push_subscribe', { p_user: s.user.id, p: p as unknown as Json }, SR)) as unknown as PushState };
  } catch (e) { return refused(e); }
}

export async function unsubscribePush(which: { endpoint?: string; id?: string }): Promise<ActionResult<PushState>> {
  const s = await signedIn();
  if (s.error) return s.error;
  try {
    return { ok: true, data: (await rpc('server_push_unsubscribe', { p_user: s.user.id, p: { endpoint: which?.endpoint ?? null, id: which?.id ?? null } }, SR)) as unknown as PushState };
  } catch (e) { return refused(e); }
}

export async function savePushTopics(topics: Topic[]): Promise<ActionResult<PushState>> {
  const s = await signedIn();
  if (s.error) return s.error;
  const clean = (Array.isArray(topics) ? topics : []).filter((t): t is Topic => (TOPICS as readonly string[]).includes(t));
  try {
    return { ok: true, data: (await rpc('server_push_set_topics', { p_user: s.user.id, p_topics: clean }, SR)) as unknown as PushState };
  } catch (e) { return refused(e); }
}

/** One alert to each of the person's devices, sent at once (not on the next five-minute tick). */
export async function sendTestPush(): Promise<ActionResult<{ queued: number }>> {
  const s = await signedIn();
  if (s.error) return s.error;
  try {
    const r = (await rpc('server_push_test', { p_user: s.user.id }, SR)) as unknown as { queued: number };
    if (r.queued) await runPushJob(20).catch(() => undefined);
    return { ok: true, data: r };
  } catch (e) { return refused(e); }
}

/** The state for this device (the card asks once it knows the browser's push address). */
export async function pushStateFor(endpoint: string | null): Promise<ActionResult<PushState>> {
  const s = await signedIn();
  if (s.error) return s.error;
  try {
    return { ok: true, data: (await rpc('server_push_state', { p_user: s.user.id, p_endpoint: endpoint ?? undefined }, SR)) as unknown as PushState };
  } catch (e) { return refused(e); }
}
