import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { assertAdmin } from '@/server/admin/data';
import { signToken } from '@/server/links';
import { calendarConsentUrl } from '@/server/meet/google';
import { siteUrl } from '@/lib/site';

// Admin > Hiring, "Connect Google Calendar" (migration 2303): an Admin goes to Google's consent screen for the company
// calendar with offline access to its events. The state is signed and bound to this browser.
export const dynamic = 'force-dynamic';
const STATE_COOKIE = 'cc-gcalendar';

export async function GET() {
  const back = (q: string) => NextResponse.redirect(`${siteUrl()}/admin/hiring?calendar=${q}`, 303);
  let admin;
  try { admin = await assertAdmin(); } catch { return NextResponse.redirect(`${siteUrl()}/sign-in?next=/admin/hiring`, 303); }
  const nonce = crypto.randomUUID();
  const url = calendarConsentUrl(await signToken('google-calendar', { u: admin.id, n: nonce }, 600));
  if (!url) return back('no-keys');
  (await cookies()).set(STATE_COOKIE, nonce, { httpOnly: true, sameSite: 'lax', path: '/api/google/calendar', maxAge: 600, secure: siteUrl().startsWith('https:') });
  return NextResponse.redirect(url, 303);
}
