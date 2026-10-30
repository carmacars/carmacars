'use server';
import { revalidatePath } from 'next/cache';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { env } from '@/lib/env';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal, VA_FN_COOKIE } from '@/server/door';

// The assistants' actions (migration 0031): the same shape as the Admin's (adminAct, adminPreview), through
// the door with the assistant's id and session. The database checks the function's allow-list and then
// the rule of the function that owns the step; its refusal is shown as written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function assertVa() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  if (!roles.va) throw new Error('Only staff with an office function may do this.');
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
  return { user, aal };
}

export async function vaAct<T = Record<string, unknown>>(action: string, p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const { user, aal } = await assertVa();
    const data = await door<T>(user.id, 'va_do', action, p, aal);
    for (const x of refresh) if (x.startsWith('/staff')) revalidatePath(x);
    if (['listing_review', 'listing_publish', 'listing_publish_now', 'review_publish', 'block_create', 'block_end', 'block_update'].includes(action)) revalidatePath('/', 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function vaPreview<T = Record<string, unknown>>(what: 'booking_preview' | 'calendar_preview' | 'bulk_rate_preview' | 'cancellation_preview' | 'quote_vehicles' | 'calendar' | 'toll_profile' | 'change_preview' | 'change_vehicles' | 'driver_links' | 'vehicle_similarity' | 'addons_for_car', p: Record<string, unknown>): Promise<R<T>> {
  try {
    const { user, aal } = await assertVa();
    return { ok: true, data: await door<T>(user.id, 'va_read', what, p, aal) };
  } catch (e) { return fail(e); }
}

/** The switcher (05-va.md section 1): an assistant who covers more than one function picks the one to work in. */
export async function switchFunction(fn: string): Promise<void> {
  const user = await currentUser();
  if (!user) redirect('/sign-in?next=/staff');
  const roles = await rolesOf(user.id);
  if (fn === 'field' && roles.field) redirect('/staff/field');
  if (!roles.va_functions?.includes(fn as never)) redirect('/staff');
  (await cookies()).set(VA_FN_COOKIE, fn, { httpOnly: true, sameSite: 'lax', path: '/', secure: env().NEXT_PUBLIC_APP_URL.startsWith('https:'), maxAge: 30 * 86400 });
  redirect('/staff');
}
