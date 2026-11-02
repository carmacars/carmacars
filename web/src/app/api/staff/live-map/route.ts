import { NextResponse } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { currentUser } from '@/server/portal/data';
import { rolesOf, sessionAal } from '@/server/door';
import { liveMap, staffLiveMap } from '@/server/admin/live-map';

// The Live map's refresh (migration 0242): the page and the TV ask every 30 seconds. Admins (with two-step sign-in when it
// is required), and since the r27 consolidation (migration 0500) customer service and Sales on their Visitors page, the
// map scoped to them (no fleet layer, no money); the database checks again. Phones and emails only with contact=1 (the
// map's "Show contact", Release 26): the same people who see them in Live now. Without it they are not in the answer at all.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function GET(req: Request) {
  const contact = new URL(req.url).searchParams.get('contact') === '1';
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const roles = await rolesOf(user.id).catch(() => null);
  try {
    if (roles?.admin) {
      const admin = await assertAdmin();
      return NextResponse.json(await liveMap(admin.id, contact, await sessionAal()), { headers: H });
    }
    const fns = roles?.va_functions ?? (roles?.va ? [roles.va] : []);
    if (!fns.some((f) => f === 'cs' || f === 'sales')) return NextResponse.json({ error: 'Admins, customer service and Sales only' }, { status: 403, headers: H });
    return NextResponse.json(await staffLiveMap(user.id, contact, await sessionAal()), { headers: H });
  } catch (e) {
    const msg = e instanceof Error ? e.message : '';
    if (/only|two-step|second|Admin/i.test(msg)) return NextResponse.json({ error: msg.slice(0, 200) }, { status: 403, headers: H });
    console.error('live map', e);
    return NextResponse.json({ error: 'The map could not be read' }, { status: 503, headers: H });
  }
}
