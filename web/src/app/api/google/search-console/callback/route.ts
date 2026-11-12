import { NextResponse, after } from 'next/server';
import { cookies } from 'next/headers';
import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { readToken } from '@/server/links';
import { gscExchange, runGscSyncNow } from '@/server/gsc/google';
import { siteUrl } from '@/lib/site';

// Google's answer to "Connect Google Search Console" (migration 2640): the same Admin, the same browser, a fresh state;
// the code becomes the refresh token, which the database puts in the vault. The first sync starts right after the
// answer (else the next five-minute tick runs it). Errors come back to Marketing > SEO as a word.
export const dynamic = 'force-dynamic';
const STATE_COOKIE = 'cc-gsc';

export async function GET(req: Request) {
  const u = new URL(req.url);
  const back = (q: string) => NextResponse.redirect(`${siteUrl()}/admin/marketing/seo?gsc=${q}`, 303);
  let admin;
  try { admin = await assertAdmin(); } catch { return NextResponse.redirect(`${siteUrl()}/sign-in?next=/admin/marketing/seo`, 303); }
  const jar = await cookies();
  const nonce = jar.get(STATE_COOKIE)?.value;
  jar.delete({ name: STATE_COOKIE, path: '/api/google/search-console' });
  const st = await readToken<{ u: string; n: string }>('google-search-console', u.searchParams.get('state'));
  if (!st || !nonce || st.n !== nonce || st.u !== admin.id) return back('state');
  const code = u.searchParams.get('code');
  if (u.searchParams.get('error') || !code) return back('declined');
  try {
    const t = await gscExchange(code);
    if (!t.scopeOk) return back('no-scope');
    if (!t.refreshToken) return back('no-refresh');
    await door(admin.id, 'admin_do', 'gsc_connect', { refresh_token: t.refreshToken, email: t.email });
    try { after(async () => { await runGscSyncNow().catch(() => undefined); }); } catch { /* the next tick runs it */ }
    return back('connected');
  } catch (e) {
    return back(/vault/i.test(e instanceof Error ? e.message : '') ? 'no-vault' : 'failed');
  }
}
