import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import { GUEST_COOKIE, guestCookieValue, newNonce, readGuestCookie } from '@/server/calls';

// r50 (5010): a candidate presses Join on their call page (/call/i/<token>). The link is used here (a POST, so an email
// scanner opening the link uses nothing): the first browser to open it gets a signed session cookie and is the only one
// that can come back to it; another browser is told the link was already used.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
export async function POST(req: Request) {
  const f = await req.formData().catch(() => null);
  const token = String(f?.get('token') ?? '');
  if (!/^[0-9a-f]{64}$/.test(token)) return NextResponse.redirect(`${siteUrl()}/careers`, { status: 303 });
  const back = `${siteUrl()}/call/i/${token}`;
  const had = await readGuestCookie();
  const nonce = had?.n ?? newNonce();
  const r = (await rpc('server_call_guest_open', { p_token: token, p_nonce: nonce }, SR)) as unknown as { ok: boolean; error?: string; link_id?: string; closes_at?: string };
  if (!r?.ok || !r.link_id) return NextResponse.redirect(`${back}?e=${encodeURIComponent(r?.error ?? 'closed')}`, { status: 303 });
  const until = new Date(r.closes_at ? Date.parse(r.closes_at) : Date.now() + 3_600_000);
  const res = NextResponse.redirect(`${back}?in=1`, { status: 303 });
  res.cookies.set(GUEST_COOKIE, await guestCookieValue(r.link_id, nonce, until), { httpOnly: true, sameSite: 'lax', secure: back.startsWith('https:'), path: '/', expires: until });
  return res;
}
