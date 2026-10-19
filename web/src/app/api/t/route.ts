import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { currentUser } from '@/server/portal/data';
import { MAX_BEACON_BYTES, cleanBeacon, isBot } from '@/lib/track/shared';
import type { Json } from '@/lib/db/types';

// Live visitors (migration 0060): the beacon when the Worker entry does not answer it (the local stack, `next start`).
// On Cloudflare custom-worker.ts answers /api/t itself, with the same checks, before the app is loaded.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  const ua = req.headers.get('user-agent');
  const e = env();
  if (isBot(ua, e.APP_ENV !== 'production' && process.env.TRACK_ALLOW_HEADLESS !== '0')) return NextResponse.json({ ok: true, bot: true }, { headers: H });
  const text = await req.text();
  if (text.length > MAX_BEACON_BYTES) return NextResponse.json({ ok: false }, { status: 413, headers: H });
  let raw: unknown;
  try { raw = JSON.parse(text); } catch { return NextResponse.json({ ok: false }, { status: 400, headers: H }); }
  const b = cleanBeacon(raw, ua);
  if (!b) return NextResponse.json({ ok: false }, { status: 400, headers: H });
  // outside production a test may say where the visitor is (Cloudflare does it in production)
  const geo = e.APP_ENV === 'production' ? {} : { city: req.headers.get('x-cc-city'), region: req.headers.get('x-cc-region'), country: req.headers.get('x-cc-country') };
  const user = await currentUser().catch(() => null);
  try {
    const out = await rpc('track_ingest', { p: b as unknown as Json, p_geo: geo as unknown as Json }, user ? { role: 'authenticated', userId: user.id } : { role: 'anon' });
    return NextResponse.json(out, { headers: H });
  } catch {
    return NextResponse.json({ ok: false }, { status: 502, headers: H });
  }
}
