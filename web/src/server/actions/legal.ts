'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// The Admin actions of the legal review (migration 0053): the Owners of the Title Schedule who sign with their own link,
// and the signing officer's countersignature of an investment agreement. The database checks every one again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

export async function addCosigner(ownerId: string, form: FormData): Promise<R<null>> {
  const name = String(form.get('name') ?? '').trim();
  const email = String(form.get('email') ?? '').trim();
  const fe: Record<string, string> = {};
  if (name.length < 2) fe.name = 'Their full legal name.';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) fe.email = 'Their email address: the signing link goes there.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'owner_cosigner_add', { owner_id: ownerId, name, email }, aal);
    revalidatePath(`/admin/owners/${ownerId}`);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export async function removeCosigner(ownerId: string, id: string, reason: string): Promise<R<null>> {
  if (!reason?.trim()) return { ok: false, code: 'invalid', message: 'Give the reason.', fieldErrors: { reason: 'Give the reason.' } };
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'owner_cosigner_remove', { id, reason: reason.trim() }, aal);
    revalidatePath(`/admin/owners/${ownerId}`);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export async function resendCosigner(ownerId: string, id: string): Promise<R<null>> {
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'owner_cosigner_send', { id }, aal);
    revalidatePath(`/admin/owners/${ownerId}`);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

/** The signing officer countersigns an investment agreement the investor signed (no automatic countersignature). */
export async function countersignInvestment(investorId: string, agreementId: string): Promise<R<null>> {
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'investment_countersign', { agreement_id: agreementId }, aal);
    revalidatePath(`/admin/investors/${investorId}`);
    revalidatePath('/investor/sign');
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
