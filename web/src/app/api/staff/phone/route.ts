import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { staffCompose, staffDoor, staffDraft, staffReply } from '@/server/phone';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { viewAs } from '@/server/view-as';
import { startStaffCall, twilioState } from '@/server/twilio-call';

// Texts and calls for staff (migration 0085): the inbox and threads poll this; replies are sent through Quo from the
// CarmaCars number; AI suggestions only fill the reply box. Admins, customer service and Sales; the database checks it
// again (app.assert_live_staff). r27 consolidation (0500): the Call and Text buttons of every staff page (fleet, finance and
// field staff too, for the people of their work): phone_buttons (is Quo on, our number), phone_compose (a text sent at once
// from the CarmaCars number, kept in the conversation) and phone_call_log (a call started from the site).
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
// r34 (0800): caller_live (the caller pop-up of Admins and customer service) and the renter notes; the database decides who
const READS = new Set(['phone_inbox', 'phone_thread', 'phone_timeline', 'phone_renter_search', 'phone_buttons', 'caller_live', 'renter_notes']);
const ACTS = new Set(['phone_read', 'phone_reply', 'phone_link', 'phone_create_lead', 'phone_opt_out', 'phone_draft', 'phone_compose', 'phone_call_log',
  'renter_note_add', 'renter_note_remove', 'caller_open', 'phone_call']);
// the buttons are for every staff member; the inbox stays Admins', customer service's and Sales's (the database decides)
const BUTTONS = new Set(['phone_buttons', 'phone_compose', 'phone_call_log', 'phone_call']);
// r35 (0970): Sales is shown masked numbers ("(647) •••-••00"); the buttons send the masked number and the server finds
// the real one (app.server_phone_unmask: only numbers this person was shown), so it never reaches the browser
const MASKED = /\u2022/;
async function realNumber(userId: string, n: string, p: Record<string, unknown>): Promise<string> {
  if (!MASKED.test(n)) return n;
  return (await rpc('server_phone_unmask', { p_user: userId, p: { masked: n, booking: typeof p.booking_number === 'string' ? p.booking_number : null, name: typeof p.name === 'string' ? p.name : null } as unknown as Json },
    { role: 'service_role' })) as unknown as string;
}
const msg = (e: unknown) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'Something went wrong');
// r27b: a busy server (a gateway's "error code: 504", a call that gave up) is never shown raw: a sentence and 503
const SLOW = /^error code: 5\d\d|<html|<!doctype|gave up|statement timeout|did not answer in time|too slow to confirm/i;
const fail = (e: unknown, status = 400) => {
  const m = msg(e);
  return SLOW.test(m)
    ? NextResponse.json({ error: 'The server was too slow to confirm it. It was not done twice: try again in a moment.', slow: true }, { status: 503, headers: H })
    : NextResponse.json({ error: m }, { status, headers: H });
};

async function who() {
  const user = await currentUser();
  if (!user) return null;
  const roles = await rolesOf(user.id);
  if (!roles.admin && !roles.va && !roles.field) return null;
  return { user, admin: roles.admin, va: !!roles.va, aal: await sessionAal() };
}

export async function GET(req: Request) {
  const w = await who();
  if (!w) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const u = new URL(req.url);
  const what = u.searchParams.get('what') ?? '';
  // r35 (0970): an Admin reveals a number masked for Sales (viewing as a Sales rep, or on their screen); audited. A read, so it
  // works in "view as" too, made as the Admin themself
  if (what === 'phone_reveal') {
    const v = await viewAs();
    const adminId = v ? v.admin.id : w.admin ? w.user.id : null;
    if (!adminId) return NextResponse.json({ error: 'Only an Admin reveals a hidden number' }, { status: 403, headers: H });
    try {
      return NextResponse.json(await door(adminId, 'admin_do', 'phone_reveal', { masked: u.searchParams.get('masked') ?? '', booking: u.searchParams.get('booking'), name: u.searchParams.get('name') }), { headers: H });
    } catch (e) { return fail(e, 403); }
  }
  if (!READS.has(what) || (!w.admin && !w.va && !BUTTONS.has(what))) return NextResponse.json({ error: 'Unknown read' }, { status: 400, headers: H });
  const p: Record<string, unknown> = {};
  for (const k of ['id', 'view', 'q', 'booking_id', 'renter_id', 'owner_id', 'lead_id', 'staff_id']) { const v = u.searchParams.get(k); if (v) p[k] = v; }
  try {
    const r = await door<Record<string, unknown>>(w.user.id, w.admin ? 'admin_read' : w.va ? 'va_read' : 'field_read', what, p, w.aal);
    // r35 (0970): whether the Call button calls through Twilio (and why not), and whether this viewer may reveal a masked number
    if (what === 'phone_buttons') { const t = twilioState(); return NextResponse.json({ ...r, twilio: t.ready, twilio_why: t.ready ? null : t.why, can_reveal: w.admin || !!(await viewAs()) }, { headers: H }); }
    return NextResponse.json(r, { headers: H });
  } catch (e) { return fail(e, 403); }
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ error: 'Not permitted' }, { status: 403, headers: H });
  const w = await who();
  if (!w) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const b = (await req.json().catch(() => null)) as ({ action?: string } & Record<string, unknown>) | null;
  if (!b?.action || !ACTS.has(b.action) || (!w.admin && !w.va && !BUTTONS.has(b.action))) return NextResponse.json({ error: 'Unknown action' }, { status: 400, headers: H });
  const { action, ...p } = b;
  const d = staffDoor(w.user.id, w.admin, w.aal);
  const call = w.va ? 'va_do' : 'field_do';
  try {
    if (action === 'phone_call') {
      // r35 (0970): the outbound Call button through Twilio (the staff member's own cell rings first); never as someone else
      if (await viewAs()) return NextResponse.json({ ok: false, fallback: null, message: 'Viewing as someone else: calls are not made from this view.' }, { headers: H });
      const n = await realNumber(w.user.id, String(p.number ?? ''), p);
      const r = await startStaffCall(w.user.id, n, typeof p.booking_number === 'string' ? p.booking_number : null);
      if (r.ok) void d(call, 'phone_call_log', { number: n, ...(typeof p.booking_number === 'string' ? { booking_number: p.booking_number } : {}) }).catch(() => undefined);
      return NextResponse.json(r, { headers: H });
    }
    if (typeof p.number === 'string' && MASKED.test(p.number)) p.number = await realNumber(w.user.id, p.number, p);
    if (action === 'phone_compose') {
      const r = await staffCompose(d, call, { number: String(p.number ?? ''), body: String(p.body ?? ''), ...(typeof p.booking_number === 'string' ? { booking_number: p.booking_number } : {}),
        ...(typeof p.key === 'string' ? { key: p.key.slice(0, 64) } : {}) });
      return NextResponse.json(r, { status: r.ok ? 200 : 502, headers: H });
    }
    if (action === 'phone_call_log') return NextResponse.json(await d(call, action, { number: String(p.number ?? ''), ...(typeof p.booking_number === 'string' ? { booking_number: p.booking_number } : {}) }), { headers: H });
    if (action === 'phone_reply') {
      const r = await staffReply(d, String(p.id ?? ''), String(p.body ?? ''));
      return NextResponse.json(r, { status: r.ok ? 200 : 502, headers: H });
    }
    if (action === 'phone_draft') {
      const r = await staffDraft(d, String(p.id ?? ''));
      return NextResponse.json(r, { headers: H });
    }
    return NextResponse.json(await d('va_do', action, p), { headers: H });
  } catch (e) { return fail(e); }
}
