import { NextResponse } from 'next/server';
import { env } from '@/lib/env';

// A referral link (06-field.md section 10; owners' codes too): the code is kept in a cookie for 30 days and
// sent with a request to book (referred_by_code); the database decides whether it earns a kickback.
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ code: string }> }) {
  const code = (await params).code.toUpperCase();
  const res = NextResponse.redirect(new URL('/cars', env().NEXT_PUBLIC_APP_URL), 302);
  if (/^[A-Z0-9]{4,12}$/.test(code)) res.cookies.set('cc-ref', code, { httpOnly: true, sameSite: 'lax', path: '/', maxAge: 30 * 86400, secure: env().NEXT_PUBLIC_APP_URL.startsWith('https:') });
  res.headers.set('x-robots-tag', 'noindex, nofollow');
  return res;
}
