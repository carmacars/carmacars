'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { kickPdfJobs } from '@/server/pdf-jobs';

// The field staff member's steps (06-field.md, migration 0031): acknowledge, start, save the checklist,
// complete the handover or the return, block a handover, vehicle moves, damage found later. The database
// checks the job is theirs and runs the function of 0020 that owns the step.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const ACTIONS = ['acknowledge', 'start', 'save_report', 'complete_handover', 'complete_return', 'block_handover', 'move_start', 'move_end', 'late_damage',
  'checklist_save', 'complete_job', 'reshoot_photo', 'report', 'profile_save', 'identity_in_person', 'deposit_offline', 'tracker_override', 'licence_approve_all', 'licence_reject'] as const;
// the steps of a check-out that staff other than field staff may take on a job of their own (0130, 0151)
const HANDOVER = ['save_report', 'complete_handover', 'complete_return', 'block_handover', 'identity_in_person', 'deposit_offline', 'tracker_override'];

export async function fieldAct<T = Record<string, unknown>>(action: typeof ACTIONS[number], p: Record<string, unknown>): Promise<R<T>> {
  try {
    if (!ACTIONS.includes(action)) return { ok: false, code: 'invalid', message: 'Unknown step.' };
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    // field staff; an Admin or an assistant on a check-out or check-in of their own (0130: the database checks the job)
    if (!roles.field && !(HANDOVER.includes(action) && (roles.admin || roles.va))) throw new Error('Only field staff may do this.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const data = await door<T>(user.id, 'field_do', action, p, aal);
    // the licence review keeps its own panel (and its message) on screen: any revalidation re-renders this page and, with nothing left
    // to review, removes the panel; the lists are refreshed when it closes (the office's pages read the database on each visit)
    const quiet = action === 'licence_approve_all' || action === 'licence_reject';
    if (!quiet) revalidatePath('/staff/field');
    if (['complete_handover', 'complete_return', 'identity_in_person', 'deposit_offline', 'tracker_override'].includes(action)) { revalidatePath('/admin/bookings', 'layout'); revalidatePath('/staff/bookings', 'layout'); }
    // 0154: the "as picked up" (or closing) copies of both agreements are rendered right after this response
    if (action === 'complete_handover' || action === 'complete_return') kickPdfJobs();
    if (typeof p.job === 'string' && !quiet) revalidatePath(`/staff/field/jobs/${p.job}`);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** Clock in or out (0165, My hours): the database checks the person is field staff and the shift's rules; its refusal is shown as written. */
export async function fieldClock<T = Record<string, unknown>>(what: 'in' | 'out', note: string | null): Promise<R<T>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (!roles.field) throw new Error('Only field staff clock in and out.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const data = await door<T>(user.id, 'ops_do', what === 'in' ? 'field_clock_in' : 'field_clock_out', { note: note?.trim() || null }, aal);
    revalidatePath('/staff/field/hours');
    revalidatePath('/staff/field');
    revalidatePath('/staff/field-hours');
    revalidatePath('/admin/money/field-pay');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
