'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import type { Availability } from '@/features/field-portal/shift-picker';

// The shift picker (r35 part SP, migration 1770): a field person's availability. Also an onboarding step, so it runs while the
// person is held (the database opens availability_save to them and checks they are field staff).
const fail = (e: unknown): ActionResult<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

export async function saveAvailability(slots: string[], note: string): Promise<ActionResult<Availability & { onboarded: boolean }>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const data = await door<Availability & { onboarded: boolean }>(user.id, 'field_do', 'availability_save', { slots: slots.slice(0, 21), note: note.slice(0, 300) }, await sessionAal());
    revalidatePath('/staff/welcome');
    revalidatePath('/staff/field', 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
