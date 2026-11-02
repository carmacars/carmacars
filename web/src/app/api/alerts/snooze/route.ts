import { NextResponse } from 'next/server';
import { realUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';
import { rpc } from '@/lib/db/repo';

// Snooze 30 min on a staff phone alert (migration 0466): the service worker (public/push-sw.js) posts the notice id; the
// alert comes again 30 minutes later and its escalation waits. Only the signed-in person's own unread alert.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ error: 'Not permitted' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  if (await viewAs()) return NextResponse.json({ error: 'Not while viewing as someone' }, { status: 403, headers: H });
  const b = (await req.json().catch(() => null)) as { id?: unknown; minutes?: unknown } | null;
  const id = typeof b?.id === 'string' && /^[0-9a-f-]{36}$/i.test(b.id) ? b.id : null;
  if (!id) return NextResponse.json({ error: 'No such alert' }, { status: 400, headers: H });
  const minutes = typeof b?.minutes === 'number' && b.minutes >= 5 && b.minutes <= 240 ? Math.round(b.minutes) : 30;
  try {
    const until = await rpc('server_alert_snooze', { p_user: user.id, p_id: id, p_minutes: minutes }, { role: 'service_role' });
    return NextResponse.json({ ok: true, until }, { headers: H });
  } catch {
    return NextResponse.json({ error: 'Not snoozed' }, { status: 400, headers: H });
  }
}
