import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { DRAFT_COOKIE } from '@/features/owner/apply-schema';
import { currentUser } from '@/server/portal/data';

// The emailed "continue on another device" link: the one-time token opens the draft here. A signed-in
// owner takes the draft into the account; a visitor's device gets its own token (the first keeps working).
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  const t = new URL(req.url).searchParams.get('t') ?? '';
  const user = await currentUser();
  try {
    const r = (await rpc('server_resume_form_draft', { p_link_token: t, p_user: user?.id, p_device_label: (req.headers.get('user-agent') ?? '').slice(0, 60) }, { role: 'service_role' })) as unknown as { token: string | null };
    const res = NextResponse.redirect(new URL('/list-your-car/apply', req.url), 303);
    if (r.token) res.cookies.set(DRAFT_COOKIE, r.token, { httpOnly: true, sameSite: 'lax', path: '/', secure: env().APP_ENV !== 'local', maxAge: 30 * 86400 });
    res.headers.set('cache-control', 'no-store');
    return res;
  } catch {
    return NextResponse.redirect(new URL('/list-your-car/apply?expired=1', req.url), 303);
  }
}
