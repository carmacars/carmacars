import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// r50 (5010): Admin: who is in the call now, who left (with their minutes) and who of the team has not joined.
export const dynamic = 'force-dynamic';
export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401 });
  const room = new URL(req.url).searchParams.get('room') ?? 'townhall';
  const v = await door(user.id, 'admin_read', 'call_live', { room: /^[a-z0-9-]{6,80}$/.test(room) ? room : 'townhall' }).catch((e: Error) => ({ error: e.message }));
  return NextResponse.json(v, { status: 'error' in (v as object) ? 403 : 200, headers: { 'cache-control': 'private, no-store' } });
}
