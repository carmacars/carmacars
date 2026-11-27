import { localRedirect } from '@/lib/http/local-redirect';
import { publicOrigin } from '@/lib/http/public-origin';
import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { auth } from '@/lib/auth';
import { enabledProviders, encodeFlow, FLOW_COOKIE, FLOW_MINUTES, isOAuthProvider } from '@/lib/auth/oauth';
import { safeNext } from '@/server/portals';

// "Continue with Google" (and the other providers when switched on): starts Supabase Auth's OAuth flow with PKCE and
// sends the browser to the provider. A plain link, not a form: the site's content security policy allows forms to post
// only to itself, and a form's redirect to the provider would count. The provider returns to /auth/callback, which
// finishes the sign-in (src/lib/auth/oauth.ts).
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  const u = new URL(req.url);
  const origin = new URL(publicOrigin(req));
  const e = env();
  const base = new URL(e.NEXT_PUBLIC_APP_URL);
  const p = u.searchParams.get('provider');
  const next = safeNext(u.searchParams.get('next'));
  if (!isOAuthProvider(p) || !enabledProviders(e.AUTH_OAUTH_PROVIDERS).includes(p)) {
    return localRedirect(`/sign-in?oauth=off&provider=${isOAuthProvider(p) ? p : ''}`);
  }
  // the code verifier is a cookie of this host: the flow starts on the host the provider returns to (the allow-listed
  // /auth/callback of the site's own address)
  if (e.DATA_BACKEND === 'supabase' && origin.host !== base.host) return NextResponse.redirect(new URL(`${u.pathname}${u.search}`, base.origin));
  const state = crypto.randomUUID();
  const r = await (await auth()).oauthStart(p, `${base.origin}/auth/callback`, state);
  if (!r.ok) return localRedirect(`/sign-in?oauth=exchange&provider=${p}`);
  const flow = encodeFlow({ p, next, intent: u.searchParams.get('intent') === 'signup' ? 'signup' : 'signin', again: u.searchParams.get('again') === '1', state, t: Date.now() });
  const res = r.url.startsWith('/') ? localRedirect(r.url) : NextResponse.redirect(r.url);
  res.cookies.set(FLOW_COOKIE, flow, { httpOnly: true, sameSite: 'lax', path: '/', secure: origin.protocol === 'https:', maxAge: FLOW_MINUTES * 60 });
  return res;
}
