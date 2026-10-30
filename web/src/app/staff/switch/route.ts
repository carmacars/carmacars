import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { realUser } from '@/server/portal/data';
import { rolesOf, VA_FN_COOKIE } from '@/server/door';

// The staff portal in one of the person's functions, from a link (the "Choose a portal" page and the portal
// switcher): the same choice as the rail's "Working as" buttons. A function the person does not have is ignored.
export const dynamic = 'force-dynamic';
// a relative Location: the browser stays on the host it asked (carmacars.ca or www), whatever the server thinks it is
const to = (path: string) => new NextResponse(null, { status: 303, headers: { location: path, 'cache-control': 'no-store' } });
export async function GET(req: Request) {
  const u = new URL(req.url);
  const fn = u.searchParams.get('fn') ?? '';
  const user = await realUser();
  if (!user) return to(`/sign-in?next=${encodeURIComponent(`/staff/switch?fn=${fn}`)}`);
  if (fn === 'field') return to('/staff/field');
  const res = to('/staff');
  const roles = await rolesOf(user.id).catch(() => null);
  if (roles?.va_functions?.includes(fn as never)) {
    res.cookies.set(VA_FN_COOKIE, fn, { httpOnly: true, sameSite: 'lax', path: '/', secure: env().NEXT_PUBLIC_APP_URL.startsWith('https:'), maxAge: 30 * 86400 });
  }
  return res;
}
