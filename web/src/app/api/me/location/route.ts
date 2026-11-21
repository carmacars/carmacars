import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { viewAs } from '@/server/view-as';
import { foreignOrigin } from '@/lib/security/same-origin';

// The live map's own-location route (migration 3350, release 48 part MAP; features/location). GET: whether this person's
// location is taken now and why (ops_read my_location). POST {action}: report (a position from the app or the browser),
// prefs ({sharing_on}) or policy ({version}, staff: the electronic monitoring policy). The database decides every time:
// staff only on shift or on a job, renters and owners only around a pickup or return; nothing else is stored.
// Never while an Admin views a portal as someone else (their position is not the person's).
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'private, no-store' };
const msg = (e: unknown) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 240) : 'That did not work. Try again.');
const ACTION = { report: 'location_report', prefs: 'location_prefs_save', policy: 'location_policy_accept' } as const;

export async function GET() {
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first' }, { status: 401, headers: H });
  if (await viewAs().catch(() => null)) return NextResponse.json({ ok: true, data: { share: false, why: 'view_as' } }, { headers: H });
  try { return NextResponse.json({ ok: true, data: await door(user.id, 'ops_read', 'my_location', {}, await sessionAal()) }, { headers: H }); }
  catch (e) { return NextResponse.json({ ok: false, message: msg(e) }, { status: 400, headers: H }); }
}

export async function POST(req: Request) {
  if (foreignOrigin(req.headers.get('origin'), req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not allowed' }, { status: 403, headers: H });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first' }, { status: 401, headers: H });
  if (await viewAs().catch(() => null)) return NextResponse.json({ ok: false, message: 'Read only while viewing as another person.' }, { status: 403, headers: H });
  const body = (await req.json().catch(() => null)) as Record<string, unknown> | null;
  const action = typeof body?.action === 'string' ? body.action : '';
  if (!(action in ACTION)) return NextResponse.json({ ok: false, message: 'Unknown action' }, { status: 400, headers: H });
  const p: Record<string, unknown> = action === 'report'
    ? { lat: Number(body!.lat), lng: Number(body!.lng), accuracy_m: Number(body!.accuracy_m ?? 0), at: typeof body!.at === 'string' ? body!.at : new Date().toISOString(), source: body!.source === 'app' ? 'app' : 'web' }
    : action === 'prefs' ? { sharing_on: body!.sharing_on !== false } : { version: String(body!.version ?? '').slice(0, 40) };
  try { return NextResponse.json({ ok: true, data: await door(user.id, 'ops_do', ACTION[action as keyof typeof ACTION], p, await sessionAal()) }, { headers: H }); }
  catch (e) { return NextResponse.json({ ok: false, message: msg(e) }, { status: 400, headers: H }); }
}
