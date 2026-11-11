import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';

// A crash in a visitor's browser (migration 0433): the error page and the window listeners post here; the database
// keeps it and opens one Admin task a day per kind. Same-origin only; small bodies only.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const s = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : undefined);

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  const text = await req.text().catch(() => '');
  if (!text || text.length > 12000) return NextResponse.json({ ok: false }, { status: 400, headers: H });
  let b: Record<string, unknown>;
  try { b = JSON.parse(text) as Record<string, unknown>; } catch { return NextResponse.json({ ok: false }, { status: 400, headers: H }); }
  // 2340: the signed-in person, so their bug reports show their own crashes
  const who = await currentUser().catch(() => null);
  const p = { message: s(b.message, 500), path: s(b.path, 300), stack: s(b.stack, 4000), digest: s(b.digest, 100), ua: s(req.headers.get('user-agent'), 300), user_id: who?.id };
  try {
    await rpc('server_client_error', { p: p as unknown as Json }, { role: 'service_role' });
  } catch (e) {
    console.error('client-error', e instanceof Error ? e.message.slice(0, 200) : e);
  }
  return NextResponse.json({ ok: true }, { headers: H });
}
