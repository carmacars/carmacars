import { NextResponse } from 'next/server';
import { VIEW_AS_COOKIE, VIEW_AS_UI_COOKIE } from '@/lib/security/view-as-guard';

// Ends "view as" (the Exit button on the red banner and in each portal's frame) and goes back to Admin > Portals.
export const dynamic = 'force-dynamic';
// a relative Location: the browser stays on the host it asked (carmacars.ca or www), whatever the server thinks it is
const to = (path: string) => new NextResponse(null, { status: 303, headers: { location: path, 'cache-control': 'no-store' } });
export async function POST() {
  const res = to('/admin/portals');
  res.cookies.delete(VIEW_AS_COOKIE);
  res.cookies.delete(VIEW_AS_UI_COOKIE);
  return res;
}
