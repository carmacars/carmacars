import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal, VA_FN_COOKIE } from '@/server/door';

// The live map's people layer (migration 3350, release 48 part MAP): staff on shift or on a job, renters and owners around
// a pickup or return. Read every 30 seconds with the map. The database decides who sees whom (ops_read live_people):
// Admin and Fleet everyone, customer service and Sales the renters at a pickup or return, anyone else no one.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'private, no-store' };

export async function GET() {
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const fn = (await cookies()).get(VA_FN_COOKIE)?.value;
  try {
    return NextResponse.json(await door(user.id, 'ops_read', 'live_people', fn ? { _va: fn } : {}, await sessionAal()), { headers: H });
  } catch (e) {
    const m = e instanceof Error ? e.message : '';
    if (/only|two-step|second/i.test(m)) return NextResponse.json({ error: m.slice(0, 200) }, { status: 403, headers: H });
    console.error('live people', e);
    return NextResponse.json({ error: 'The people on the map could not be read' }, { status: 503, headers: H });
  }
}
