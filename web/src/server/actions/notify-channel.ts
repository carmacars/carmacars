'use server';
import { revalidatePath } from 'next/cache';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { isChannel, type Channel, type Reach } from '@/features/phone/alerts';

// Text alerts (migration 0096): the signed-in person chooses how we reach them (Email, Text or Both). The database
// works out what that means now (a verified phone, STOP, the US gate) and the routing follows it.
const SR = { role: 'service_role' as const };
const PROFILE_PATHS = ['/account/profile', '/owner/profile', '/investor/profile', '/va/profile', '/field/profile'];

export async function saveMyChannel(channel: Channel): Promise<ActionResult<Reach>> {
  if (!isChannel(channel)) return { ok: false, code: 'invalid', message: 'Choose Email, Text or Both.' };
  const user = await (await auth()).currentUser();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  try {
    const r = (await rpc('server_set_notify_channel', { p_user: user.id, p_channel: channel }, SR)) as unknown as Reach;
    for (const p of PROFILE_PATHS) revalidatePath(p);
    return { ok: true, data: r };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Not saved. Try again.' };
  }
}
