import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { env } from '@/lib/env';
import { decodeFlow, FLOW_COOKIE, isOAuthProvider, OAUTH_PROVIDERS } from '@/lib/auth/oauth';

// LOCAL ONLY: the stand-in for the provider's consent page (Google's "Choose an account"), so the tests run the whole
// flow without Google. The tester types the address the provider would vouch for (and may untick "verified"); the
// page sends the browser to /auth/callback with a code, as Supabase Auth does after the provider. "Cancel" returns
// the provider's refusal. On the second pass of a flow (an address on file, src/lib/auth/oauth.ts) it answers at once
// with the same account, as Google does for an account that already agreed. Not found on Supabase or in production.
export const dynamic = 'force-dynamic';
const REMEMBER = 'cc-oauth-fake';
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export async function GET(req: Request) {
  const e = env();
  if (e.DATA_BACKEND !== 'local' || e.APP_ENV === 'production') return new NextResponse('Not found', { status: 404 });
  const u = new URL(req.url);
  const jar = await cookies();
  const flow = decodeFlow(jar.get(FLOW_COOKIE)?.value);
  const provider = u.searchParams.get('provider');
  const state = u.searchParams.get('state') ?? '';
  if (!flow || !isOAuthProvider(provider) || flow.p !== provider || flow.state !== state) return new NextResponse('This sign-in has expired. Start again.', { status: 400 });
  if (u.searchParams.get('cancel') === '1') return NextResponse.redirect(new URL('/auth/callback?error=access_denied&error_description=The+user+denied+access', u.origin));
  let email = (u.searchParams.get('email') ?? '').trim().toLowerCase();
  let name = (u.searchParams.get('name') ?? '').trim();
  let verified = u.searchParams.get('verified') === 'on';
  if (!email && flow.again) {
    try { const r = JSON.parse(jar.get(REMEMBER)?.value ?? '') as { email: string; name: string }; email = r.email; name = r.name; verified = true; } catch { /* the page then */ }
  }
  if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    const { localOAuthCode } = await import('@/lib/auth/local');
    const code = await localOAuthCode({ provider, email, name, verified, state });
    const res = NextResponse.redirect(new URL(`/auth/callback?code=${encodeURIComponent(code)}`, u.origin));
    res.cookies.set(REMEMBER, JSON.stringify({ email, name }), { httpOnly: true, sameSite: 'lax', path: '/', maxAge: 600 });
    return res;
  }
  const label = OAUTH_PROVIDERS[provider].label;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${label} (local stand-in)</title>
<style>body{font:16px/1.5 system-ui,sans-serif;margin:0;padding:24px;background:#f6f6f6;color:#1f1f1f}main{max-width:26rem;margin:0 auto;background:#fff;padding:24px;border-radius:8px;border:1px solid #ddd}label{display:block;margin:12px 0 4px}input[type=email],input[type=text]{width:100%;padding:10px;box-sizing:border-box;border:1px solid #747775;border-radius:4px;font:inherit}.row{display:flex;gap:12px;margin-top:20px}button,a{font:inherit;padding:10px 16px;border-radius:4px}button{background:#1f1f1f;color:#fff;border:0}a{color:#1f1f1f}</style></head>
<body><main><h1>Sign in with ${label}</h1><p>Local stand-in for ${label}'s page. Nothing leaves this computer.</p>
<form method="get" action="/auth/oauth/fake"><input type="hidden" name="provider" value="${esc(provider)}"><input type="hidden" name="state" value="${esc(state)}">
<label for="fo-email">Email</label><input id="fo-email" name="email" type="email" required autocomplete="off" data-testid="fake-oauth-email">
<label for="fo-name">Name</label><input id="fo-name" name="name" type="text" autocomplete="off" data-testid="fake-oauth-name">
<label><input type="checkbox" name="verified" checked data-testid="fake-oauth-verified"> ${label} has verified this email</label>
<div class="row"><button type="submit" data-testid="fake-oauth-continue">Continue</button><a href="/auth/oauth/fake?provider=${esc(provider)}&amp;state=${esc(state)}&amp;cancel=1" data-testid="fake-oauth-cancel">Cancel</a></div></form></main></body></html>`;
  return new NextResponse(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
}
