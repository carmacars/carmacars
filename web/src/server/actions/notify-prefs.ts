'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import type { Json } from '@/lib/db/types';
import type { Portal, PrefChange, PrefState } from '@/features/notifications/prefs';

// Notification preferences (release 48, migration 3260): one change at a time, for the signed-in person (every portal
// and the app), for a person by an Admin (through the door, logged with who), or for a referral partner from their
// portal link. The database refuses a locked type and a type of another portal; its words are shown as written.
const SR = { role: 'service_role' as const };
type R = ActionResult<PrefState>;
const PORTALS: Portal[] = ['renter', 'owner', 'investor', 'staff', 'admin', 'partner'];
const fail = (e: unknown): R => ({ ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Not saved. Please try again.' });
const PATHS = ['/account/profile', '/owner/account', '/staff/profile', '/staff/field/profile', '/admin/settings/profile', '/investor/profile'];

/** Only the fields a change may carry, typed (nothing else from the browser reaches the database). */
function clean(c: PrefChange): Record<string, unknown> | null {
  const x = c as Record<string, unknown>;
  if (typeof x.type === 'string') {
    if (!/^[a-z][a-z0-9_]{2,40}$/.test(x.type) || !['push', 'email', 'text'].includes(String(x.channel)) || typeof x.on !== 'boolean') return null;
    return { type: x.type, channel: x.channel, on: x.on };
  }
  if (typeof x.cadence === 'string') return ['instant', 'daily', 'weekly'].includes(x.cadence) ? { cadence: x.cadence } : null;
  if (typeof x.all_off === 'boolean') return { all_off: x.all_off };
  const out: Record<string, unknown> = {};
  if (typeof x.quiet_on === 'boolean') out.quiet_on = x.quiet_on;
  for (const k of ['quiet_from', 'quiet_until'] as const) {
    if (x[k] === undefined) continue;
    const n = Number(x[k]);
    if (!Number.isInteger(n) || n < 0 || n > 1439) return null;
    out[k] = n;
  }
  return Object.keys(out).length ? out : null;
}

export async function saveMyNotifyPref(portal: Portal, change: PrefChange): Promise<R> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    const p = clean(change);
    if (!p || !PORTALS.includes(portal)) return { ok: false, code: 'invalid', message: 'That choice is not one of the options.' };
    const data = (await rpc('server_notify_prefs_save' as never, { p_user: user.id, p: { ...p, portal } as unknown as Json } as never, SR)) as unknown as PrefState;
    for (const x of PATHS) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** An Admin changes a person's preferences (Admin > Settings > Notifications). */
export async function saveNotifyPrefFor(userId: string, portal: Portal, change: PrefChange): Promise<R> {
  try {
    const me = await currentUser();
    if (!me) return { ok: false, code: 'auth', message: 'Sign in first.' };
    const p = clean(change);
    if (!p || !/^[0-9a-f-]{36}$/.test(userId)) return { ok: false, code: 'invalid', message: 'That choice is not one of the options.' };
    const data = await door<PrefState>(me.id, 'admin_do', 'notify_pref_set', { ...p, user: userId, portal }, await sessionAal());
    revalidatePath('/admin/settings/notifications');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** A referral partner, from their portal link: the id and the key of the link are checked as the portal checks them. */
export async function savePartnerNotifyPref(id: string, key: string, change: PrefChange): Promise<R> {
  try {
    const p = clean(change);
    if (!p || !/^[0-9a-f-]{36}$/.test(id)) return { ok: false, code: 'invalid', message: 'That choice is not one of the options.' };
    const { loadPortal } = await import('@/server/referral/portal');
    if (!(await loadPortal(id, key))) return { ok: false, code: 'auth', message: 'This link is no longer valid. Ask CarmaCars for a new one.' };
    const data = (await rpc('server_partner_notify_prefs_save' as never, { p_partner: id, p: p as unknown as Json } as never, SR)) as unknown as PrefState;
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
