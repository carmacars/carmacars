import { NextResponse } from 'next/server';
import { door } from '@/server/door';
import { realUser } from '@/server/portal/data';
import { foreignOrigin } from '@/lib/security/same-origin';

// Add old photos (5185), the bulk flow: for each group of photos (its capture times and the plate read from it, if any) the
// check-in or check-out nearest in time, on that car when the plate matched one. The database decides (app.old_photo_suggest).
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function POST(req: Request) {
  if (foreignOrigin(req.headers.get('origin'), req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const body = (await req.json().catch(() => null)) as { groups?: unknown } | null;
  if (!Array.isArray(body?.groups) || body.groups.length > 200) return NextResponse.json({ ok: false, message: 'Send the groups.' }, { status: 400, headers: H });
  const groups = body.groups.map((g) => {
    const x = (g ?? {}) as Record<string, unknown>;
    return { i: Number(x.i) || 0, from: typeof x.from === 'string' ? x.from : null, to: typeof x.to === 'string' ? x.to : null, plate: typeof x.plate === 'string' ? x.plate.slice(0, 12) : null };
  });
  try {
    return NextResponse.json({ ok: true, ...(await door<Record<string, unknown>>(user.id, 'ops_read', 'old_photo_suggest', { groups })) }, { headers: H });
  } catch (e) {
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not permitted.' }, { status: 403, headers: H });
  }
}
