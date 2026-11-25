import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';
import { guestSession, recordEvent, type JoinAs, type Joined } from '@/server/calls';

// r50 (5010): the page's own join, heartbeat (every 30 s) and leave: the attendance is recorded even when the media
// server's webhook is late or the fake media of CI is used. The room and the person come from the session, never the body.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'private, no-store' };
export async function POST(req: Request) {
  const b = (await req.json().catch(() => ({}))) as { as?: JoinAs; guest?: boolean; event?: string };
  const ev = b.event === 'joined' || b.event === 'left' || b.event === 'seen' ? b.event : null;
  if (!ev) return NextResponse.json({ error: 'event' }, { status: 400, headers: H });
  try {
    if (b.guest) {
      const s = await guestSession();
      if (!s) return NextResponse.json({ error: 'closed' }, { status: 403, headers: H });
      await recordEvent(s.room, s.identity, ev);
      return NextResponse.json({ ok: true }, { headers: H });
    }
    const user = await currentUser();
    if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
    const as = b.as?.room === 'interview' ? { room: 'interview', application_id: String(b.as.application_id ?? '') } : { room: 'townhall' };
    const j = await door<Joined>(user.id, as.room === 'interview' ? 'admin_read' : 'ops_read', 'call_join', as);
    await recordEvent(j.room, j.identity, ev);
    return NextResponse.json({ ok: true }, { headers: H });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 403, headers: H });
  }
}
