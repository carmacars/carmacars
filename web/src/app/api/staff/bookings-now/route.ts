import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { sessionAal } from '@/server/door';
import { bookingsNow } from '@/server/bookings-now';

// Bookings > Now's refresh (migration 0330): the page asks every 30 seconds while it is visible. Signed in only; the
// database decides who may read it (Admins, fleet and customer service, field staff without the money) and checks the
// second factor as on every page. ?as=field reads the field staff view; ?va= the office function worked in.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const FNS = new Set(['cs', 'fleet', 'finance', 'sales']);

export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: 'Sign in again' }, { status: 401, headers: H });
  const q = new URL(req.url).searchParams;
  const va = q.get('va');
  try {
    return NextResponse.json(await bookingsNow(user.id, { field: q.get('as') === 'field', va: va && FNS.has(va) ? va : null, aal: await sessionAal() }), { headers: H });
  } catch (e) {
    const msg = e instanceof Error ? e.message : '';
    if (/only|two-step|second/i.test(msg)) return NextResponse.json({ error: msg }, { status: 403, headers: H });
    console.error('bookings now', e);
    return NextResponse.json({ error: 'The board could not be read' }, { status: 503, headers: H });
  }
}
