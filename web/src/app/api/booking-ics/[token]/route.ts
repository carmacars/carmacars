import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { bookingIcs } from '@/features/portal/booking-ics';

// The calendar file of a confirmed booking (migration 0215), from the confirmation email's link: pickup and return as two
// events. The token is the booking's calendar_token; only the car, the times and the place are in it.
export const dynamic = 'force-dynamic';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function GET(_req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const head = { 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow' };
  if (!UUID.test(token)) return new NextResponse('Not found', { status: 404, headers: head });
  const b = (await rpc('server_booking_calendar', { p_token: token }, { role: 'service_role' }).catch(() => null)) as unknown as
    { number: string; car: string; pickup_at: string; return_at: string; pickup_place: string; return_place: string | null } | null;
  if (!b) return new NextResponse('This booking is not confirmed, or the link is wrong.', { status: 404, headers: head });
  return new NextResponse(bookingIcs(b), { headers: { ...head, 'content-type': 'text/calendar; charset=utf-8', 'content-disposition': `attachment; filename="${b.number}.ics"` } });
}
