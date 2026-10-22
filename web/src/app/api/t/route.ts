import { NextResponse, after } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { currentUser } from '@/server/portal/data';
import { BEACON_WAIT_MS, BEAT_WAIT_MS, MAX_BEACON_BYTES, cleanBeacon, cleanBeat, isBeat, isBot, within } from '@/lib/track/shared';
import type { Json } from '@/lib/db/types';

// Live visitors (migration 0060): the beacon when the Worker entry does not answer it (the local stack, `next start`).
// On Cloudflare custom-worker.ts answers /api/t itself, with the same checks, before the app is loaded.
// 0103, as the Worker: the heartbeat (app.track_beat), and the database call never holds the browser. A batch waits for
// it at most 2 seconds and a heartbeat 1.5 seconds, then the answer is 204 and the call finishes after the response
// (after()); the last batch of a page is answered 204 at once and ends the session once its events are in.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const none = () => new Response(null, { status: 204, headers: H });

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
  const background = <T,>(p: Promise<T>) => { const q = p.catch(() => undefined); after(() => q); return q; };

  if (isBeat(raw)) {
    const beat = cleanBeat(raw);
    if (!beat) return NextResponse.json({ ok: false }, { status: 400, headers: H });
    const p = background(rpc('track_beat', { p: beat as unknown as Json }, { role: 'anon' }));
    if (beat.end) return none();
    const out = await within(p, BEAT_WAIT_MS);
    return out ? NextResponse.json(out, { headers: H }) : none();
  }

  const b = cleanBeacon(raw, ua);
  if (!b) return NextResponse.json({ ok: false }, { status: 400, headers: H });
  const { end, ...batch } = b;
  // outside production a test may say where the visitor is (Cloudflare does it in production)
  const geo = e.APP_ENV === 'production' ? {} : { city: req.headers.get('x-cc-city'), region: req.headers.get('x-cc-region'), country: req.headers.get('x-cc-country') };
  const user = await currentUser().catch(() => null);
  const p = background((async () => {
    const out = await rpc('track_ingest', { p: batch as unknown as Json, p_geo: geo as unknown as Json }, user ? { role: 'authenticated', userId: user.id } : { role: 'anon' });
    if (end) await rpc('track_beat', { p: { sid: b.sid, vid: b.vid, end: '1' } as unknown as Json }, { role: 'anon' });
    return out;
  })());
  if (end) return none();
  const out = await within(p, BEACON_WAIT_MS);
  return out ? NextResponse.json(out, { headers: H }) : none();
}
