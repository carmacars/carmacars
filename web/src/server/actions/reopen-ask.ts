'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { pendingView } from '@/server/capture';
import { findBooking, realUser } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';
import { askPickupError } from '@/features/offers/pickup-passed';

// The renter asks to reopen an expired offer (0569): from the offer page (signed in) or /my-request (this device's
// unverified session, whose user must be the booking's renter). A To do and an alert for the requests team, once per
// 6 hours (the database checks the renter and the limit again).
type R = { ok: true; already: boolean } | { ok: false; message: string };
export async function askReopenOffer(number: string, pickupLocalIso: string | null): Promise<R> {
  const bad = askPickupError(pickupLocalIso);
  if (bad) return { ok: false, message: bad };
  const pickup = pickupLocalIso ? new Date(pickupLocalIso) : null;
  try {
    let by: string | null = null;
    const user = await realUser().catch(() => null);
    if (user) {
      const b = await findBooking(user, number);
      if (!b) return { ok: false, message: 'Booking not found.' };
      by = user.id;
    } else {
      const v = await pendingView();
      if (!v || !v.bookings.some((x) => x.number === number)) return { ok: false, message: 'Open the link in your email to continue.' };
      by = v.user_id;
    }
    const r = (await rpc('server_renter_ask_reopen' as never, { p_number: number, p_by: by, p_pickup: pickup ? pickup.toISOString() : null } as never, { role: 'service_role' })) as unknown as { already?: boolean };
    revalidatePath(bookingPath(number)); revalidatePath('/my-request');
    return { ok: true, already: Boolean(r?.already) };
  } catch (e) {
    return { ok: false, message: e instanceof DbError ? e.message : 'Something went wrong. Please call or text us.' };
  }
}
