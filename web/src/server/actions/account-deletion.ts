'use server';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import type { DeletionState } from '@/features/app-shell/deletion';

// Delete my account (migration 0390; Apple's rule for apps with sign-up, and the same on the site): the signed-in person
// asks, or withdraws the request. The database opens the Admin's task and keeps the request.
const SR = { role: 'service_role' as const };

async function me() {
  const user = await (await auth()).currentUser();
  return user ?? null;
}
const refused = (e: unknown) => ({ ok: false as const, code: 'refused', message: e instanceof DbError ? e.message : 'Not sent. Try again.' });

export async function requestAccountDeletion(reason: string): Promise<ActionResult<DeletionState>> {
  const user = await me();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  try {
    const why = typeof reason === 'string' ? reason.trim().slice(0, 500) : '';
    return { ok: true, data: (await rpc('server_request_account_deletion', { p_user: user.id, p_reason: why || undefined }, SR)) as unknown as DeletionState };
  } catch (e) { return refused(e); }
}

export async function withdrawAccountDeletion(): Promise<ActionResult<DeletionState>> {
  const user = await me();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  try {
    return { ok: true, data: (await rpc('server_withdraw_account_deletion', { p_user: user.id }, SR)) as unknown as DeletionState };
  } catch (e) { return refused(e); }
}
