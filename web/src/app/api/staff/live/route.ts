import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';

// Live visitors and Live chat for staff (migration 0060): the pages poll this every few seconds (short polling: one
// small read through the door, no open connection), and every action goes the same way. Admins, customer service
// and Sales only; the database checks it again (app.assert_live_staff).
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const READS = new Set(['live_visitors', 'live_session', 'vehicle_interest', 'visitor_timeline', 'chat_inbox', 'chat_thread', 'chat_counts']);
const ACTS = new Set(['chat_prefs', 'chat_start', 'chat_take', 'chat_reply', 'chat_hand_back', 'chat_close', 'chat_typing', 'chat_transcript']);
const msg = (e: unknown) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'Something went wrong');

async function who() {
  const user = await currentUser();
  if (!user) return null;
  const roles = await rolesOf(user.id);
  if (!roles.admin && !roles.va) return null;
  return { user, admin: roles.admin, aal: await sessionAal() };
}

export async function GET(req: Request) {
  const w = await who();
  if (!w) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const u = new URL(req.url);
  const what = u.searchParams.get('what') ?? '';
  if (!READS.has(what)) return NextResponse.json({ error: 'Unknown read' }, { status: 400, headers: H });
  const p: Record<string, unknown> = {};
  for (const k of ['id', 'after', 'vehicle_id', 'renter_id', 'booking_id']) { const v = u.searchParams.get(k); if (v) p[k] = v; }
  try {
    return NextResponse.json(await door(w.user.id, w.admin ? 'admin_read' : 'va_read', what, p, w.aal), { headers: H });
  } catch (e) { return NextResponse.json({ error: msg(e) }, { status: 403, headers: H }); }
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ error: 'Not permitted' }, { status: 403, headers: H });
  const w = await who();
  if (!w) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const b = (await req.json().catch(() => null)) as ({ action?: string } & Record<string, unknown>) | null;
  if (!b?.action || !ACTS.has(b.action)) return NextResponse.json({ error: 'Unknown action' }, { status: 400, headers: H });
  const { action, ...p } = b;
  try {
    return NextResponse.json(await door(w.user.id, w.admin ? 'admin_do' : 'va_do', action, p, w.aal), { headers: H });
  } catch (e) { return NextResponse.json({ error: msg(e) }, { status: 400, headers: H }); }
}
