import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';
import { siteUrl } from '@/lib/site';
import { townhallIcs, type Townhall } from '@/features/townhall/model';

// 1062: the weekly townhall as a calendar invite (signed-in staff only): repeats every week at the set day and time.
export const dynamic = 'force-dynamic';
export async function GET() {
  const user = await currentUser();
  if (!user) return new NextResponse('Sign in first', { status: 401 });
  const v = await door<Townhall>(user.id, 'ops_read', 'townhall', {}).catch(() => null);
  if (!v?.next_at) return new NextResponse('Not available', { status: 404 });
  return new NextResponse(townhallIcs({ nextAt: v.next_at, minutes: v.minutes, url: v.call_url, base: siteUrl() }),
    { headers: { 'content-type': 'text/calendar; charset=utf-8', 'content-disposition': 'attachment; filename="carmacars-townhall.ics"', 'cache-control': 'private, no-store' } });
}
