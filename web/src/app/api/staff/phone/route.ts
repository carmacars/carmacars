import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { staffDoor, staffDraft, staffReply } from '@/server/phone';

// Texts and calls for staff (migration 0085): the inbox and threads poll this; replies are sent through Quo from the
// CarmaCars number; AI suggestions only fill the reply box. Admins, customer service and Sales; the database checks it
// again (app.assert_live_staff).
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const READS = new Set(['phone_inbox', 'phone_thread', 'phone_timeline', 'phone_renter_search']);
const ACTS = new Set(['phone_read', 'phone_reply', 'phone_link', 'phone_create_lead', 'phone_opt_out', 'phone_draft']);
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
  for (const k of ['id', 'view', 'q', 'booking_id', 'renter_id', 'owner_id', 'lead_id', 'staff_id']) { const v = u.searchParams.get(k); if (v) p[k] = v; }
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
  const d = staffDoor(w.user.id, w.admin, w.aal);
  try {
    if (action === 'phone_reply') {
      const r = await staffReply(d, String(p.id ?? ''), String(p.body ?? ''));
      return NextResponse.json(r, { status: r.ok ? 200 : 502, headers: H });
    }
    if (action === 'phone_draft') {
      const r = await staffDraft(d, String(p.id ?? ''));
      return NextResponse.json(r, { headers: H });
    }
    return NextResponse.json(await d('va_do', action, p), { headers: H });
  } catch (e) { return NextResponse.json({ error: msg(e) }, { status: 400, headers: H }); }
}
