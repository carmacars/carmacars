import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// r50 hotfix 2 (5150): the weekly Admin call as a calendar file (Admins only): the same event the emailed invite carries
// (its UID, the weekly RRULE, Toronto time, the call page as its place), as METHOD:PUBLISH, built by the database.
export const dynamic = 'force-dynamic';
export async function GET() {
  const user = await currentUser();
  if (!user) return new NextResponse('Sign in first', { status: 401 });
  const v = await door<{ ics: string | null }>(user.id, 'admin_read', 'admin_call_ics', {}).catch(() => null);
  if (!v?.ics) return new NextResponse('Not available', { status: 404 });
  return new NextResponse(v.ics, { headers: { 'content-type': 'text/calendar; charset=utf-8', 'content-disposition': 'attachment; filename="carmacars-admin-call.ics"', 'cache-control': 'private, no-store' } });
}
