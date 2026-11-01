import { NextResponse } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { sessionAal } from '@/server/door';
import { liveMap } from '@/server/admin/live-map';

// The Live map's refresh (migration 0242): the page and the TV ask every 30 seconds. Admins only (with two-step sign-in
// when it is required); the database checks again. Phones and emails only with contact=1 (the map's "Show contact",
// Release 26): the same Admins who see them on the renter and lead pages (requireAdmin there, assertAdmin here).
// Without it they are not in the answer at all.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function GET(req: Request) {
  let user;
  try { user = await assertAdmin(); } catch (e) { return NextResponse.json({ error: e instanceof Error ? e.message : 'Admins only' }, { status: 401, headers: H }); }
  const contact = new URL(req.url).searchParams.get('contact') === '1';
  try {
    return NextResponse.json(await liveMap(user.id, contact, await sessionAal()), { headers: H });
  } catch (e) {
    console.error('live map', e);
    return NextResponse.json({ error: 'The map could not be read' }, { status: 503, headers: H });
  }
}
