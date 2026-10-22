import { NextResponse } from 'next/server';
import { auth } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import { ensureSignIn, PENDING_COOKIE } from '@/server/capture';
import { safeNext } from '@/server/portals';

// The link of the "Continue your request" email (migration 0090). The token opens the account it was sent for (the
// database keeps only its hash); each opening makes a fresh one-time sign-in link of the sign-in service, which the
// callback verifies: that signs the person in AND confirms the email in the same step (every unverified session of the
// account then ends), and lands on the draft or request. An email scanner opening it first does not spend it.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function GET(req: Request) {
  const u = new URL(req.url);
  const t = u.searchParams.get('t') ?? '';
  const away = (path: string) => {
    const res = NextResponse.redirect(new URL(path, u.origin));
    res.headers.set('cache-control', 'no-store');
    res.headers.set('referrer-policy', 'no-referrer');
    return res;
  };
  if (!/^[0-9a-f]{64}$/.test(t)) return away('/link-expired?kind=password');
  const r = (await rpc('server_capture_continue_open', { p_token: t }, SR).catch(() => null)) as unknown as
    { ok: boolean; error?: string; user_id?: string; email?: string; name?: string; next?: string; make_sign_in?: boolean } | null;
  if (!r?.ok || !r.email || !r.user_id) return away(r?.error === 'used' ? '/sign-in' : '/link-expired?kind=password');
  if (r.make_sign_in) await ensureSignIn(r.user_id, r.email, r.name ?? r.email).catch(() => undefined);
  const a = await auth();
  const link = a.continueLink ? await a.continueLink(r.email, safeNext(r.next ?? null) ?? '/account') : null;
  if (!link?.ok) return away('/link-expired?kind=password');
  const res = NextResponse.redirect(link.link);
  res.headers.set('cache-control', 'no-store');
  res.headers.set('referrer-policy', 'no-referrer');
  // the unverified session of this browser (if any) ends once the email is confirmed; its cookie goes now
  res.cookies.delete(PENDING_COOKIE);
  return res;
}
