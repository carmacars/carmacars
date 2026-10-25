import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { requestMeta } from '@/server/request';
import { affiliateDestination, asPlacement } from '@/features/referral/model';

// The RentalCoverage link on the site (migration 0164): every place that suggests coverage from another company links here.
// The click is counted (the place on the site, the visitor's cookie, the booking when the visitor had one) and the visitor is sent
// on to the affiliate link with UTM tags. While the program is off, or the link is not usable, nothing is counted and the visitor
// lands on Requirements and coverage.
export const dynamic = 'force-dynamic';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function GET(req: Request) {
  const u = new URL(req.url);
  const place = asPlacement(u.searchParams.get('p'));
  const booking = (u.searchParams.get('b') ?? '').slice(0, 40);
  const meta = await requestMeta();
  const vid = (await cookies()).get('cc_vid')?.value ?? '';
  const back = () => { const r = NextResponse.redirect(new URL('/requirements#coverage', env().NEXT_PUBLIC_APP_URL), 302); r.headers.set('x-robots-tag', 'noindex, nofollow'); return r; };
  try {
    const c = (await rpc('server_coverage_click', { p: { placement: place, visitor_id: UUID.test(vid) ? vid : null, booking_number: /^[A-Za-z0-9-]{3,40}$/.test(booking) ? booking : null }, p_ip: meta.ip ?? undefined }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; link_url?: string; affiliate_id?: string | null };
    const to = c?.ok ? affiliateDestination(c.link_url, c.affiliate_id, place) : null;
    if (!to) return back();
    const r = NextResponse.redirect(to, 302);
    r.headers.set('x-robots-tag', 'noindex, nofollow');
    r.headers.set('referrer-policy', 'strict-origin-when-cross-origin');
    return r;
  } catch { return back(); }
}
