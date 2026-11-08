import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { auth } from '@/lib/auth';
import { landingFor, safeNext } from '@/server/portals';
import { rolesOf } from '@/server/door';
import { rpc } from '@/lib/db/repo';
import { cookies } from 'next/headers';
import { decodeFlow, FLOW_COOKIE } from '@/lib/auth/oauth';
import { finishProviderSignIn } from '@/server/oauth-sign-in';

// Supabase Auth email links land here with a token hash (every template: scripts/deploy/auth-templates.mjs) or a
// one-time code (PKCE, a link asked for on this same browser). Either becomes a session cookie; then the person
// continues to `next` (choosing a password: /update-password, which then sends them to their portal). A link that
// has expired or was used already goes to /link-expired, which sends a new one in one step.
//
// The sign-up confirmation link carries no `next`: the person lands in their own portal, by role (an owner who applied
// from List your car lands in /owner, someone with two or more portals on "Choose a portal", a renter in /account).
// Older confirmation links carried next=/account; for a confirmation that is read the same way (by role).
export const dynamic = 'force-dynamic';
// The link proved the person controls the address: what was made earlier with it (booking requests, a place as an
// additional driver) is attached to the sign-in now (migration 0040), and the welcome email goes once (0045). Never
// blocks the sign-in.
async function verified(id: string | undefined, email: string | undefined) {
  if (!id || !email) return;
  await rpc('server_account_email_verified', { p_user: id, p_email: email }, { role: 'service_role' }).catch(() => undefined);
}
const TYPES = new Set(['invite', 'recovery', 'email', 'signup', 'magiclink', 'email_change']);
const CONFIRM = new Set(['signup', 'email', 'magiclink']);

/** r33: a link of a change of sign-in email was opened. With both links needed (the old address is told with a link of its own) the first one
 *  leaves the change waiting for the other; once the sign-in holds the new address the contact records follow it (migration 0742) and the
 *  person lands in their own portal with a note. */
async function emailChanged(user: { id?: string; email?: string; new_email?: string | null } | null | undefined, asked: string | null): Promise<string> {
  const id = user?.id;
  if (!id) return '/account';
  const landing = landingFor(await rolesOf(id).catch(() => ({}) as never));
  // the person's profile, where the form that started the change says what happened (?email=changed or waiting)
  const where = asked && asked !== '/account' ? asked
    : landing.startsWith('/staff/field') ? '/staff/field/profile' : landing.startsWith('/staff') ? '/staff/profile' : landing.startsWith('/owner') ? '/owner/account'
    : landing.startsWith('/investor') ? '/investor/profile' : landing.startsWith('/account') ? '/account/profile' : landing;
  const note = (v: string) => `${where}${where.includes('?') ? '&' : '?'}email=${v}`;
  if (user?.new_email) return note('waiting');
  if (user?.email) {
    const r = (await rpc('server_account_email_changed', { p_user: id, p_email: user.email }, { role: 'service_role' }).catch(() => null)) as unknown as { ok?: boolean } | null;
    if (r?.ok) { await verified(id, user.email); return note('changed'); }
  }
  return note('waiting');
}

/** Where the link goes once it has signed the person in. */
async function target(type: string, asked: string | null, userId: string | undefined): Promise<string> {
  if (asked && !(CONFIRM.has(type) && asked === '/account')) return asked;
  if (!CONFIRM.has(type) && type) return asked ?? '/update-password';
  if (!userId) return '/account';
  return landingFor(await rolesOf(userId).catch(() => ({}) as never));
}

export async function GET(req: Request) {
  const u = new URL(req.url);
  const asked = safeNext(u.searchParams.get('next'));
  const code = u.searchParams.get('code');
  const tokenHash = u.searchParams.get('token_hash');
  const type = u.searchParams.get('type') ?? '';
  const backend = env().DATA_BACKEND;
  // sign-in with a provider (src/lib/auth/oauth.ts): this browser started the flow (its cookie) and the provider sent
  // the person back, with a code or with a refusal (cancelled on the provider's page)
  const jar = await cookies();
  const flow = decodeFlow(jar.get(FLOW_COOKIE)?.value);
  if (flow && !tokenHash && (code || u.searchParams.get('error'))) {
    jar.delete(FLOW_COOKIE);
    if (!code) {
      const reason = u.searchParams.get('error') === 'access_denied' ? 'cancelled' : 'exchange';
      return NextResponse.redirect(new URL(`/sign-in?oauth=${reason}&provider=${flow.p}`, u.origin));
    }
    const r = await finishProviderSignIn(code, flow);
    return NextResponse.redirect(new URL(r.to, u.origin));
  }
  if (backend === 'supabase' && tokenHash && TYPES.has(type)) {
    const { supabaseServer } = await import('@/lib/supabase/server');
    const s = await supabaseServer();
    const { data, error } = await s.auth.verifyOtp({ token_hash: tokenHash, type: type as 'invite' });
    if (!error) {
      if (type === 'email_change') return NextResponse.redirect(new URL(await emailChanged(data.user, asked), u.origin));
      await verified(data.user?.id, data.user?.email);
      return NextResponse.redirect(new URL(await target(type, asked, data.user?.id), u.origin));
    }
  } else if (backend === 'supabase' && code) {
    const { supabaseServer } = await import('@/lib/supabase/server');
    const s = await supabaseServer();
    const { data, error } = await s.auth.exchangeCodeForSession(code);
    if (!error) {
      await verified(data.user?.id, data.user?.email);
      return NextResponse.redirect(new URL(await target(type || 'signup', asked, data.user?.id), u.origin));
    }
  } else if (backend !== 'supabase' && tokenHash && type === 'email_change') {
    const r = await (await auth()).confirmEmailChange?.(tokenHash);
    if (r?.ok) return NextResponse.redirect(new URL(await emailChanged({ id: r.user.id, email: r.user.email }, asked), u.origin));
  } else if (backend !== 'supabase' && tokenHash && CONFIRM.has(type)) {
    // the local stand-in for Supabase Auth (src/lib/auth/local.ts): the same confirmation link, checked locally
    const r = await (await auth()).confirmEmail?.(tokenHash);
    if (r?.ok) {
      await verified(r.user.id, r.user.email);
      return NextResponse.redirect(new URL(await target(type, asked, r.user.id), u.origin));
    }
  }
  // Supabase sends people here with ?error=...&error_code=otp_expired when its own page refused the link
  const kind = type === 'signup' || type === 'email' ? 'confirm' : type === 'invite' ? 'invite' : 'password';
  return NextResponse.redirect(new URL(`/link-expired?kind=${kind}`, u.origin));
}
