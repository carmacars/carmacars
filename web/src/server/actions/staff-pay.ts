'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { encryptField, PAYOUT_KEY_VERSION } from '@/server/crypto';
import { checkPayDetails, type PayDetailsInput, type PayDetailsView } from '@/features/staff/pay-details';

// A staff member's own pay details (release 33, migration 0730): asked for by one-step Hire (the welcome email's link and a
// first-day To do), entered here in their profile. The account number is encrypted before it leaves the server (as an
// owner's, 0022) and only its last 4 digits are ever shown again; an Admin verifies new details.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

export async function savePayDetails(portal: 'va' | 'field', p: PayDetailsInput): Promise<R<PayDetailsView>> {
  const fe = checkPayDetails(p);
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  try {
    if (portal !== 'va' && portal !== 'field') return { ok: false, code: 'invalid', message: 'Unknown portal.' };
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (portal === 'va' ? !roles.va : !roles.field) throw new Error('Only staff may do this.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const account = (p.account_no ?? '').replace(/[\s-]/g, '');
    const withNumber = p.method === 'bank_transfer' || p.method === 'gcash';
    const r = await door<PayDetailsView>(user.id, portal === 'va' ? 'va_do' : 'field_do', 'my_pay_details_save', {
      method: p.method, account_holder: p.account_holder.trim(), country: p.country?.trim() || null, bank_name: p.bank_name?.trim() || null,
      institution_no: p.institution_no?.trim() || null, transit_no: p.transit_no?.trim() || null, email: p.email?.trim() || null,
      ...(withNumber ? { account_no: await encryptField(account), account_last4: account.slice(-4), key_version: PAYOUT_KEY_VERSION } : {}) }, aal);
    revalidatePath(portal === 'va' ? '/staff/profile' : '/staff/field/profile');
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}
