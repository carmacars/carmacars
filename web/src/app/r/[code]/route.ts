import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { REFERRAL_COOKIE_DAYS } from '@/features/referral/model';

// A referral link (06-field.md section 10; owners' codes too): the code is kept in a cookie for 30 days and sent with a request
// to book (referred_by_code); the database decides whether it earns a kickback. A referral partner's code (migration 0164:
// a body shop, a tow truck, ...) is kept for 60 days.
export const dynamic = 'force-dynamic';
export async function GET(req: Request, { params }: { params: Promise<{ code: string }> }) {
  const code = (await params).code.toUpperCase();
  // ?to=owner (0217): an owner's link for a new owner opens the owner program page; the same cookie credits the referrer
  const to = new URL(req.url).searchParams.get('to') === 'owner' ? '/list-your-car' : '/cars';
  const res = NextResponse.redirect(new URL(to, env().NEXT_PUBLIC_APP_URL), 302);
  if (/^[A-Z0-9]{4,12}$/.test(code)) {
    const partner = (await rpc('referral_partner_code_ok', { p_code: code }, { role: 'anon' }).catch(() => false)) as unknown as boolean;
    res.cookies.set('cc-ref', code, { httpOnly: true, sameSite: 'lax', path: '/', maxAge: (partner ? REFERRAL_COOKIE_DAYS : 30) * 86400, secure: env().NEXT_PUBLIC_APP_URL.startsWith('https:') });
  }
  res.headers.set('x-robots-tag', 'noindex, nofollow');
  return res;
}
