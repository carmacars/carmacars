'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { bookingPath } from '@/features/portal/status';
import { findBooking, requireUser } from '@/server/portal/data';
import type { Walk } from '@/features/walkthrough/model';

// The rental walkthrough (migration 0291): the renter marks a step as read ("Got it"). The booking is checked as theirs
// here (public.my_booking under row-level security) and again in the database (p_by is the renter).
const SR = { role: 'service_role' as const };
const STEPS = new Set(['bring', 'meet', 'own_photos', 'rules', 'help', 'return_prep']);

export async function walkthroughGotIt(number: string, step: string): Promise<ActionResult<Walk>> {
  if (!STEPS.has(step)) return { ok: false, code: 'invalid', message: 'Unknown step.' };
  try {
    const user = await requireUser(bookingPath(number, 'walkthrough'));
    const b = await findBooking(user, number);
    if (!b) return { ok: false, code: 'refused', message: 'Booking not found.' };
    const w = (await rpc('server_my_walkthrough_ack', { p_booking: b.id, p_by: user.id, p_step: step }, SR)) as unknown as Walk;
    revalidatePath(bookingPath(number));
    return { ok: true, data: w };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'That did not save. Try again.' };
  }
}
