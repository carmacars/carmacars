import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { assertAdmin } from '@/server/admin/data';
import { signToken } from '@/server/links';
import { consentUrl } from '@/server/reviews/google';
import { siteUrl } from '@/lib/site';

// Admin > Settings > Reviews, "Connect Google" (migration 0146): an Admin is sent to Google's consent screen for
// rent@carmacars.ca with offline access to the Business Profile. The state is signed and bound to this browser.
export const dynamic = 'force-dynamic';
const STATE_COOKIE = 'cc-greviews';

export async function GET() {
  const back = (q: string) => NextResponse.redirect(`${siteUrl()}/admin/settings/reviews?google=${q}`, 303);
  let admin;
  try { admin = await assertAdmin(); } catch { return NextResponse.redirect(`${siteUrl()}/sign-in?next=/admin/settings/reviews`, 303); }
  const nonce = crypto.randomUUID();
  const state = await signToken('google-reviews', { u: admin.id, n: nonce }, 600);
  const url = consentUrl(state);
  if (!url) return back('no-keys');
  (await cookies()).set(STATE_COOKIE, nonce, { httpOnly: true, sameSite: 'lax', path: '/api/google/reviews', maxAge: 600, secure: siteUrl().startsWith('https:') });
  return NextResponse.redirect(url, 303);
}
