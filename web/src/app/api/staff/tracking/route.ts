import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// Fleet tracking's refresh (migration 0400): the dashboard asks every 15 seconds while it is visible, and for a trip's
// route when one is chosen (?trip=). Admins and fleet staff only: the database checks the person on every call.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const trip = new URL(req.url).searchParams.get('trip');
  try {
    const aal = await sessionAal();
    const data = trip && /^[0-9a-f-]{36}$/i.test(trip)
      ? await door(user.id, 'ops_read', 'tracker_trip_path', { trip }, aal)
      : await door(user.id, 'ops_read', 'tracker_fleet', {}, aal);
    return NextResponse.json(data, { headers: H });
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Could not read';
    return NextResponse.json({ error: msg }, { status: /Admins and fleet staff|Sign in|Two-step/.test(msg) ? 403 : 503, headers: H });
  }
}
