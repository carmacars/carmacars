import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { guestSession, staffTicket, ticketFor, type JoinAs } from '@/server/calls';

// r50 (5010): the media server's short token for the call the page is on: a signed-in staff member or Admin (the database
// checks the room through call_join), or a candidate through their link's signed session. Never cached.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'private, no-store' };
export async function POST(req: Request) {
  const b = (await req.json().catch(() => ({}))) as { as?: JoinAs; guest?: boolean };
  try {
    if (b.guest) {
      const s = await guestSession();
      if (!s) return NextResponse.json({ error: 'This call link is no longer open on this browser.' }, { status: 403, headers: H });
      return NextResponse.json(await ticketFor(s.room, s.identity, s.name, 'guest'), { headers: H });
    }
    const user = await currentUser();
    if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
    const as = b.as?.room === 'interview' ? { room: 'interview' as const, application_id: String(b.as.application_id ?? '') } : { room: 'townhall' as const };
    return NextResponse.json((await staffTicket(user.id, as)).ticket, { headers: H });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message || 'The call could not be opened' }, { status: 403, headers: H });
  }
}
