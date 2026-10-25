import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { readToken } from '@/server/links';
import { exchangeCode } from '@/server/reviews/google';
import { siteUrl } from '@/lib/site';

// Google's answer to "Connect Google" (migration 0146): the same Admin, the same browser, a fresh state; the code becomes
// the refresh token, which the database puts in the vault. Errors come back to the settings screen as a word.
export const dynamic = 'force-dynamic';
const STATE_COOKIE = 'cc-greviews';

export async function GET(req: Request) {
  const u = new URL(req.url);
  const back = (q: string) => NextResponse.redirect(`${siteUrl()}/admin/settings/reviews?google=${q}`, 303);
  let admin;
  try { admin = await assertAdmin(); } catch { return NextResponse.redirect(`${siteUrl()}/sign-in?next=/admin/settings/reviews`, 303); }
  const jar = await cookies();
  const nonce = jar.get(STATE_COOKIE)?.value;
  jar.delete({ name: STATE_COOKIE, path: '/api/google/reviews' });
  const st = await readToken<{ u: string; n: string }>('google-reviews', u.searchParams.get('state'));
  if (!st || !nonce || st.n !== nonce || st.u !== admin.id) return back('state');
  if (u.searchParams.get('error')) return back('declined');
  const code = u.searchParams.get('code');
  if (!code) return back('declined');
  try {
    const t = await exchangeCode(code);
    if (!t.refreshToken) return back('no-refresh');
    await door(admin.id, 'admin_do', 'review_google_connect', { refresh_token: t.refreshToken, email: t.email });
    return back('connected');
  } catch (e) {
    return back(/vault/i.test(e instanceof Error ? e.message : '') ? 'no-vault' : 'failed');
  }
}
