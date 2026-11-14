'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';

// "Accept this card" (release 48, migration 2912): the card's name differs from the renter's a little more than the
// tolerant check allows; an Admin, or staff who verify bookings, accepts it with a short reason. The database checks
// the person and logs the reason on the booking's history; the "Check the name on the card" To do is closed.
export async function acceptCardName(booking: string, reason: string): Promise<ActionResult<null>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    if (!/^[0-9a-f-]{36}$/.test(booking)) throw new Error('Booking not found');
    await rpc('staff_accept_card_name', { p_by: user.id, p_booking: booking, p_reason: reason.slice(0, 300) }, { role: 'service_role' });
    for (const p of ['/admin', '/staff']) revalidatePath(p, 'layout');
    return { ok: true, data: null };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
