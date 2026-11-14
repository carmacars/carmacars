import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';
import { foreignOrigin } from '@/lib/security/same-origin';
import { cookies } from 'next/headers';

// A crash in a visitor's browser (migration 0433): the error page and the window listeners post here; the database
// keeps it and opens one Admin task a day per page and message (2895: real crashes only; noise is kept, never a task). Same-origin only; small bodies only.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const s = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : undefined);

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  const text = await req.text().catch(() => '');
  if (!text || text.length > 12000) return NextResponse.json({ ok: false }, { status: 400, headers: H });
  let b: Record<string, unknown>;
  try { b = JSON.parse(text) as Record<string, unknown>; } catch { return NextResponse.json({ ok: false }, { status: 400, headers: H }); }
  // 2340: the signed-in person, so their bug reports show their own crashes
  const who = await currentUser().catch(() => null);
  // 2895: the browser's visitor id, so the To do counts people and not reports (nobody signed in)
  const vid = who ? undefined : await cookies().then((c) => c.get('cc_vid')?.value).catch(() => undefined);
  const p = { visitor: vid && /^[0-9A-Za-z-]{8,64}$/.test(vid) ? vid : undefined, message: s(b.message, 500), path: s(b.path, 300), stack: s(b.stack, 4000), digest: s(b.digest, 100), ua: s(req.headers.get('user-agent'), 300), user_id: who?.id };
  try {
    await rpc('server_client_error', { p: p as unknown as Json }, { role: 'service_role' });
  } catch (e) {
    console.error('client-error', e instanceof Error ? e.message.slice(0, 200) : e);
  }
  return NextResponse.json({ ok: true }, { headers: H });
}
