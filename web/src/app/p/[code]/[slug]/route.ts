import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { PARTNER_COOKIE } from '@/features/partner-crm/feed-key';

// A partner's booking link (migration 0136): /p/<partner code>/<car>. The partner's code is kept for 30 days and sent with
// a request to book (public.server_partner_referral), so the partner gets the lead in their CRM; then the car's page.
export const dynamic = 'force-dynamic';

export async function GET(_req: Request, { params }: { params: Promise<{ code: string; slug: string }> }) {
  const { code, slug } = await params;
  const base = env().NEXT_PUBLIC_APP_URL;
  const okSlug = /^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug);
  const res = NextResponse.redirect(new URL(okSlug ? `/cars/${slug}` : '/cars', base), 302);
  const c = code.toLowerCase();
  if (/^[a-z0-9]+(-[a-z0-9]+)*$/.test(c) && c.length <= 30) {
    const known = (await rpc('partner_referral_code_ok', { p_code: c }, { role: 'anon' }).catch(() => false)) as unknown as boolean;
    if (known) res.cookies.set(PARTNER_COOKIE, c, { httpOnly: true, sameSite: 'lax', path: '/', maxAge: 30 * 86400, secure: base.startsWith('https:') });
  }
  res.headers.set('x-robots-tag', 'noindex, nofollow');
  return res;
}
