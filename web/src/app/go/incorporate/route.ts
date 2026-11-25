import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';

// Incorporate now (r50, 4511): the owner pipeline's step for an owner whose route needs a corporation links here. For the
// signed-in owner of the car, the referral is recorded (who, which car, when, with a code for the provider's report) and
// the owner is sent on to the provider's affiliate link. While the referral is off, or for anyone else, the owner lands on
// the car's page.
export const dynamic = 'force-dynamic';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function GET(req: Request) {
  const v = new URL(req.url).searchParams.get('v') ?? '';
  const base = env().NEXT_PUBLIC_APP_URL;
  const back = () => { const r = NextResponse.redirect(new URL(UUID.test(v) ? `/owner/vehicles/${v}#stages` : '/owner', base), 302); r.headers.set('x-robots-tag', 'noindex, nofollow'); return r; };
  if (!UUID.test(v)) return back();
  try {
    const user = await currentUser();
    if (!user) return NextResponse.redirect(new URL(`/sign-in?next=${encodeURIComponent(`/go/incorporate?v=${v}`)}`, base), 302);
    const c = (await rpc('server_incorporation_click', { p_by: user.id, p: { vehicle_id: v } }, { role: 'service_role' })) as unknown as { ok: boolean; url?: string | null };
    if (!c?.ok || !c.url || !/^https:\/\//.test(c.url)) return back();
    const r = NextResponse.redirect(c.url, 302);
    r.headers.set('x-robots-tag', 'noindex, nofollow');
    r.headers.set('referrer-policy', 'strict-origin-when-cross-origin');
    return r;
  } catch { return back(); }
}
