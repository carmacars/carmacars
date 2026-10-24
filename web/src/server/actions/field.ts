'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';

// The field staff member's steps (06-field.md, migration 0031): acknowledge, start, save the checklist,
// complete the handover or the return, block a handover, vehicle moves, damage found later. The database
// checks the job is theirs and runs the function of 0020 that owns the step.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const ACTIONS = ['acknowledge', 'start', 'save_report', 'complete_handover', 'complete_return', 'block_handover', 'move_start', 'move_end', 'late_damage',
  'checklist_save', 'complete_job', 'reshoot_photo', 'report', 'profile_save'] as const;

export async function fieldAct<T = Record<string, unknown>>(action: typeof ACTIONS[number], p: Record<string, unknown>): Promise<R<T>> {
  try {
    if (!ACTIONS.includes(action)) return { ok: false, code: 'invalid', message: 'Unknown step.' };
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    // field staff; an Admin or an assistant on a check-out or check-in of their own (0130: the database checks the job)
    if (!roles.field && !(['save_report', 'complete_handover', 'complete_return', 'block_handover'].includes(action) && (roles.admin || roles.va))) throw new Error('Only field staff may do this.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const data = await door<T>(user.id, 'field_do', action, p, aal);
    revalidatePath('/field');
    if (action === 'complete_handover' || action === 'complete_return') { revalidatePath('/admin/bookings', 'layout'); revalidatePath('/va/bookings', 'layout'); }
    if (typeof p.job === 'string') revalidatePath(`/field/jobs/${p.job}`);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
