'use server';
import { revalidatePath } from 'next/cache';
import type { ActionResult } from '@/features/forms/schemas';
import { door, sessionAal } from '@/server/door';
import { assertAdmin } from '@/server/admin/data';
import { oneStepHire, sendHireAgreement } from '@/server/hire';
import type { HireStatus, StandardPay } from '@/features/careers/hire';

// One-step Hire (release 33, migration 0730; before: 0173's invitation only): one confirm creates the staff sign-in and its
// invitation, records the hire with the role, start date and pay, closes the interview items, sends the welcome email with
// the pay details link, enrolls the academy with the gate on, schedules the first-day To do's and sends the staff agreement.
const fail = (e: unknown): ActionResult<never> => ({ ok: false, code: 'refused', message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const uuid = (s: string) => /^[0-9a-f-]{36}$/i.test(s ?? '');
const refresh = (id: string) => { revalidatePath('/admin/hiring'); revalidatePath(`/admin/hiring/${id}`); };

export interface HirePreview { can_hire: boolean; function: string; start_on: string; pay: StandardPay; standard_pay: Record<string, StandardPay>; will_do: string[];
  functions: Array<{ code: string; label: string }>; application: { full_name: string; email: string | null; status: string }; /** 1067 */ outside_area?: boolean }

/** The Hire form's defaults and what one confirm will do. */
export async function hirePreview(id: string, fn?: string | null): Promise<ActionResult<HirePreview>> {
  try {
    const admin = await assertAdmin();
    if (!uuid(id)) return { ok: false, code: 'invalid', message: 'Choose a candidate.' };
    return { ok: true, data: await door<HirePreview>(admin.id, 'admin_read', 'hire_preview', { id, function: fn || null }) };
  } catch (e) { return fail(e); }
}

export async function hireApplicant(i: { id: string; function: string; start_on: string; pay_cents?: number | null; pay_currency?: string | null }): Promise<ActionResult<HireStatus>> {
  try {
    const admin = await assertAdmin();
    const r = await oneStepHire(admin.id, await sessionAal(), i);
    refresh(i.id);
    return r.ok ? { ok: true, data: r.status } : { ok: false, code: 'refused', message: r.message };
  } catch (e) { return fail(e); }
}

/** The agreement again: once the hire entered what it waited for (their home address, their licence number). */
export async function sendHireAgreementNow(id: string): Promise<ActionResult<HireStatus>> {
  try {
    const admin = await assertAdmin();
    if (!uuid(id)) return { ok: false, code: 'invalid', message: 'Choose a candidate.' };
    const aal = await sessionAal();
    const s = await door<HireStatus>(admin.id, 'admin_read', 'hire_status', { id }, aal);
    if (!s.onboarding || !s.user_id) return { ok: false, code: 'refused', message: 'This candidate was not hired with one-step Hire.' };
    const out = await sendHireAgreement(admin.id, aal, id, s.user_id, s);
    refresh(id);
    return { ok: true, data: out };
  } catch (e) { return fail(e); }
}

/** An Admin confirms a hire's new pay details (how: a call, a message they started). */
export async function verifyStaffPay(applicationId: string, payoutId: string, method: string): Promise<ActionResult<null>> {
  try {
    const admin = await assertAdmin();
    if (!uuid(payoutId)) return { ok: false, code: 'invalid', message: 'Choose the pay details.' };
    if ((method ?? '').trim().length < 3) return { ok: false, code: 'invalid', message: 'Say how you checked them.', fieldErrors: { method: 'Say how you checked them.' } };
    await door(admin.id, 'admin_do', 'staff_payout_verify', { id: payoutId, method: method.trim() });
    if (uuid(applicationId)) refresh(applicationId);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
