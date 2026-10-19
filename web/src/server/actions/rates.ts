'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import type { RateCheck } from '@/features/rates/rates';

// The rate form (migration 0064): one check of the rates and the kilometre terms together (with the examples priced by
// the booking pricing function) and one save. Admins and Fleet; the database checks who may.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

/** Check rates without saving. p: vehicle (or class, make, model for a car not added yet) and the fields. */
export async function rateCheck(p: Record<string, unknown>): Promise<R<RateCheck>> {
  try { const { user, aal } = await me(); return { ok: true, data: await door<RateCheck>(user.id, 'ops_read', 'rate_card_check', p, aal) }; } catch (e) { return fail(e); }
}

/** Save a car's rates and kilometre terms in one step. */
export async function rateSave(p: Record<string, unknown>, refresh: string[] = []): Promise<R<{ id: string }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ id: string }>(user.id, 'ops_do', 'rate_card_save', p, aal);
    for (const x of ['/cars/[slug]', '/rent/[hub]']) revalidatePath(x, 'page');
    revalidatePath('/cars'); revalidatePath('/', 'layout');
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
