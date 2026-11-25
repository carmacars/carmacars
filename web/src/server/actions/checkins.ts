'use server';
import { revalidatePath } from 'next/cache';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { refusalMessage } from '@/lib/db/refusal';
import { bookingPath } from '@/features/portal/status';
import { requireUser } from '@/server/portal/data';
import type { Visit } from '@/features/checkins/model';

// Monthly check-in visits (release 50, migration 4000): the renter picks a time, asks for one by request, or takes the
// time back. The database checks the booking is theirs, the slot is still free, and tells Fleet.
const SR = { role: 'service_role' as const };

export async function bookCheckin(number: string, p: { slot_at?: string; place?: 'office' | 'request'; note?: string; cancel?: boolean }): Promise<ActionResult<{ visit: Visit }>> {
  try {
    const user = await requireUser(bookingPath(number, 'check-in'));
    const data = (await rpc('server_checkin_book', { p_user: user.id, p: { booking: number, ...p } as unknown as Json }, SR)) as unknown as { visit: Visit };
    revalidatePath(bookingPath(number, 'check-in')); revalidatePath(bookingPath(number)); revalidatePath('/account');
    return { ok: true, data };
  } catch (e) { return { ok: false, code: 'refused', message: refusalMessage(e) }; }
}
