import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { assertAdmin } from '@/server/admin/data';
import { signToken } from '@/server/links';
import { gscConsentUrl } from '@/server/gsc/google';
import { siteUrl } from '@/lib/site';

// Marketing > SEO, "Connect Google Search Console" (migration 2640): an Admin goes to Google's consent screen for the
// account that owns the Search Console property, with offline access. The state is signed and bound to this browser.
export const dynamic = 'force-dynamic';
const STATE_COOKIE = 'cc-gsc';

export async function GET() {
  const back = (q: string) => NextResponse.redirect(`${siteUrl()}/admin/marketing/seo?gsc=${q}`, 303);
  let admin;
  try { admin = await assertAdmin(); } catch { return NextResponse.redirect(`${siteUrl()}/sign-in?next=/admin/marketing/seo`, 303); }
  const nonce = crypto.randomUUID();
  const url = gscConsentUrl(await signToken('google-search-console', { u: admin.id, n: nonce }, 600));
  if (!url) return back('no-keys');
  (await cookies()).set(STATE_COOKIE, nonce, { httpOnly: true, sameSite: 'lax', path: '/api/google/search-console', maxAge: 600, secure: siteUrl().startsWith('https:') });
  return NextResponse.redirect(url, 303);
}
