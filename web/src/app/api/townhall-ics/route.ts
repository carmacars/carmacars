import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// 1062, r50 (5000): the weekly townhall as a calendar file (signed-in staff only): the same event the emailed invite carries
// (its UID, the weekly RRULE, Toronto time, the call page as its place), as METHOD:PUBLISH, built by the database.
export const dynamic = 'force-dynamic';
export async function GET() {
  const user = await currentUser();
  if (!user) return new NextResponse('Sign in first', { status: 401 });
  const v = await door<{ ics: string | null }>(user.id, 'ops_read', 'townhall_ics', {}).catch(() => null);
  if (!v?.ics) return new NextResponse('Not available', { status: 404 });
  return new NextResponse(v.ics, { headers: { 'content-type': 'text/calendar; charset=utf-8', 'content-disposition': 'attachment; filename="carmacars-townhall.ics"', 'cache-control': 'private, no-store' } });
}
