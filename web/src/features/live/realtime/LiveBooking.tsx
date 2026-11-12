import 'server-only';
import { currentUser } from '@/server/portal/data';
import { liveBookingToken } from '@/server/live';
import { LiveRefresh } from './LiveRefresh';

// Live updates (release 41): a booking's page and its sub pages (handover, report, deposit review ...) for Admin and
// staff watch that one booking (its status, money, agreement, jobs), not every booking (the frame's bookings area is off
// on these paths, areas.ts). No token (the person may not read it): the page simply does not update live.
export async function LiveBooking({ number }: { number: string }) {
  const user = await currentUser().catch(() => null);
  const topic = user ? await liveBookingToken(user.id, number) : null;
  return topic ? <LiveRefresh topics={[topic]} /> : null;
}
