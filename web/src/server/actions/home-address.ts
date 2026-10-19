'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';

// A staff member saves their own home address (migration 0059): at their first sign-in to the VA or field portal, in the
// staff agreement signing step, or in their profile. It is needed before they add a rental or earn a commission (the
// household check). The database checks the person and the address again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

export async function saveHomeAddress(portal: 'va' | 'field', homeAddress: string, postalCode: string): Promise<R<{ missing: boolean }>> {
  try {
    if (portal !== 'va' && portal !== 'field') return { ok: false, code: 'invalid', message: 'Unknown portal.' };
    const address = homeAddress.trim();
    const postal = postalCode.trim();
    if (!address) return { ok: false, code: 'invalid', message: 'Write your home address.' };
    if (!postal) return { ok: false, code: 'invalid', message: 'Write your postal code.' };
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (portal === 'va' ? !roles.va : !roles.field) throw new Error('Only staff may do this.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const r = await door<{ missing: boolean }>(user.id, portal === 'va' ? 'va_do' : 'field_do', 'home_address_save', { home_address: address, home_postal_code: postal }, aal);
    revalidatePath(`/${portal}`, 'layout');
    return { ok: true, data: { missing: !!r.missing } };
  } catch (e) { return fail(e); }
}
