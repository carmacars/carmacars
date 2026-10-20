import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';
import { ipKey } from '@/lib/track/shared';
import { env } from '@/lib/env';

// Discount games (migration 0069): the claim. The game itself (settings, the play, the reveal) is read straight from
// the database by the browser; only the claim comes here, once per visitor at most, so the server can check the
// visitor is not signed in and rate-limit by a salted key of the network address (the address is never stored). The
// database checks everything again, creates the code, the lead and the task, and queues the email.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const H = { 'cache-control': 'no-store' };
const str = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : undefined);
const int = (v: unknown, max: number) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(Math.round(v), max)) : 0);

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  const b = (await req.json().catch(() => null)) as Record<string, unknown> | null;
  if (!b || typeof b.token !== 'string' || !/^[0-9a-f]{64}$/.test(b.token)) return NextResponse.json({ ok: false, error: 'not_found', message: 'This game has ended. Reload the page.' }, { status: 400, headers: H });
  const user = await currentUser().catch(() => null);
  const ip = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? null;
  const p = {
    token: b.token, first_name: str(b.first_name, 80), email: str(b.email, 200), phone: str(b.phone, 40), marketing: b.marketing === true,
    sid: str(b.sid, 36), cars_viewed: int(b.cars_viewed, 500), pages_viewed: int(b.pages_viewed, 5000), seconds: int(b.seconds, 86400),
    city: req.headers.get('cf-ipcity'), region: req.headers.get('cf-region-code'), country: req.headers.get('cf-ipcountry'),
    ip_key: await ipKey(ip, (env().SUPABASE_SERVICE_ROLE_KEY ?? 'local').slice(-24)).catch(() => null)
  };
  try {
    const r = await rpc('server_game_claim', { p: p as unknown as Json, p_user: user?.id }, SR);
    return NextResponse.json(r, { headers: H });
  } catch (e) {
    console.error('game claim', e instanceof Error ? e.message.slice(0, 300) : e);
    return NextResponse.json({ ok: false, error: 'unavailable', message: 'We could not send the code. Please try again.' }, { status: 500, headers: H });
  }
}
