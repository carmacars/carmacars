import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { rpc } from '@/lib/db/repo';

const SR = { role: 'service_role' as const };

// r35 S2 (1055): the person's newest unread staff alert (a new request or an accepted offer), polled by the portals'
// AlertPulse to show a toast with a pulse. Admins and staff (office and field) only; nothing else leaves here.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
export async function GET() {
  const user = await currentUser();
  if (!user) return NextResponse.json({ latest: null }, { status: 401, headers: H });
  const roles = await rolesOf(user.id);
  // field staff wear the same staff frame (and its AlertPulse), so they read their own newest alert too
  if (!roles.admin && !roles.va && !roles.field) return NextResponse.json({ latest: null }, { status: 403, headers: H });
  const d = await rpc('server_alert_latest', { p_user: user.id }, SR).catch(() => null);
  return NextResponse.json(d ?? { latest: null }, { headers: H });
}
