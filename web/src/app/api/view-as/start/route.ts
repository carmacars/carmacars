import { NextResponse } from 'next/server';
import { rpc, DbError } from '@/lib/db/repo';
import { auth } from '@/lib/auth';
import { adminGate } from '@/server/admin/data';
import { PORTAL_HOME, viewAsCookieOptions, viewAsCookieValue, type ViewPortal, type VaFn } from '@/server/view-as';
import { VIEW_AS_COOKIE, VIEW_AS_UI_COOKIE } from '@/lib/security/view-as-guard';

// Starts "view as" (a form on Admin > Portals, Staff, Owners and Investors): the Admin is checked here and again by
// the database (app.view_as_start, which also writes the start to the audit log), then the signed cookie is set and
// the person's portal opens. A form post from this site only (SameSite cookies, and the Origin is checked).
export const dynamic = 'force-dynamic';
// a relative Location: the browser stays on the host it asked (carmacars.ca or www), whatever the server thinks it is
const back = (msg: string) => to(`/admin/portals?error=${encodeURIComponent(msg)}`);
const to = (path: string) => new NextResponse(null, { status: 303, headers: { location: path, 'cache-control': 'no-store' } });
const PORTALS = new Set<ViewPortal>(['account', 'owner', 'va', 'field', 'investor']);


export async function POST(req: Request) {
  // a form on this site only: the Origin's host is the host the request was sent to
  const origin = req.headers.get('origin');
  const host = req.headers.get('x-forwarded-host') ?? req.headers.get('host');
  if (origin && (() => { try { return new URL(origin).host !== host; } catch { return true; } })()) return new NextResponse('Forbidden', { status: 403 });
  const a = await auth();
  const admin = await a.currentUser();
  if (!admin) return to('/sign-in?next=/admin/portals');
  const gate = await adminGate(admin);
  if (!gate.admin) return to('/admin/no-access');
  if (gate.two_step_required && (await a.assurance()) !== 'aal2') return to('/two-step?next=/admin/portals');
  const fd = await req.formData();
  // one select can carry "person|portal|function"; separate fields work too
  const [pick0, pick1, pick2] = String(fd.get('pick') ?? '').split('|');
  const target = String(fd.get('user') ?? pick0 ?? '');
  const portal = String(fd.get('portal') ?? pick1 ?? '') as ViewPortal;
  const fn = (String(fd.get('fn') ?? pick2 ?? '') || null) as VaFn | null;
  if (!/^[0-9a-f-]{36}$/i.test(target)) return back('Choose a person first.');
  if (!PORTALS.has(portal)) return back('Choose a portal.');
  let v: { user_id: string; email: string; name: string; portal: ViewPortal; function: VaFn | null };
  try {
    v = (await rpc('server_view_as_start', { p_admin: admin.id, p_target: target, p_portal: portal, p_fn: fn ?? undefined }, { role: 'service_role', skipViewAs: true })) as unknown as typeof v;
  } catch (e) {
    return back(e instanceof DbError ? e.message : 'That view could not be opened.');
  }
  const res = to(PORTAL_HOME[portal]);
  const opts = viewAsCookieOptions();
  res.cookies.set(VIEW_AS_COOKIE, await viewAsCookieValue(admin.id, v), opts);
  res.cookies.set(VIEW_AS_UI_COOKIE, `${v.name} (${v.email})`, { ...opts, httpOnly: false });
  return res;
}
