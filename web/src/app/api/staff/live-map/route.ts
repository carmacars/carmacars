import { NextResponse } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { sessionAal } from '@/server/door';
import { liveMap } from '@/server/admin/live-map';

// The Live map's refresh (migration 0242): the page and the TV ask every 30 seconds. Admins only (with two-step sign-in
// when it is required); the database checks again. Masked unless details=1 (the normal page's "Show details").
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function GET(req: Request) {
  let user;
  try { user = await assertAdmin(); } catch (e) { return NextResponse.json({ error: e instanceof Error ? e.message : 'Admins only' }, { status: 401, headers: H }); }
  const details = new URL(req.url).searchParams.get('details') === '1';
  try {
    return NextResponse.json(await liveMap(user.id, details, await sessionAal()), { headers: H });
  } catch (e) {
    console.error('live map', e);
    return NextResponse.json({ error: 'The map could not be read' }, { status: 503, headers: H });
  }
}
