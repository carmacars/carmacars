import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { isBot } from '@/lib/track/shared';

// The phone number box (migration 0280): the box was shown, or closed without a number. Sent with navigator.sendBeacon
// only when a visitor taps something the box guards (never for a page view); counted per day, no personal data.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  if (isBot(req.headers.get('user-agent'), true)) return NextResponse.json({ ok: true }, { headers: H });
  const b = (await req.json().catch(() => null)) as { e?: unknown; gate?: unknown; vid?: unknown } | null;
  if (!b || (b.e !== 'shown' && b.e !== 'closed') || !['gallery', 'dates', 'request'].includes(String(b.gate))) return NextResponse.json({ ok: false }, { status: 400, headers: H });
  const vid = typeof b.vid === 'string' && UUID.test(b.vid) ? b.vid : null;
  try {
    await rpc('server_phone_gate_event', { p: { visitor_id: vid, gate: b.gate, event: b.e } as unknown as Json }, { role: 'service_role' });
  } catch (e) {
    console.error('phone-gate', e instanceof Error ? e.message.slice(0, 200) : e);
  }
  return NextResponse.json({ ok: true }, { headers: H });
}
