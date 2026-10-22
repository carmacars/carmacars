import { NextResponse } from 'next/server';
import { capture } from '@/server/capture';

// Contact capture (migration 0090): one save from a form, as the person types (name, email, phone only). Same-origin
// only; the database rate-limits by browser and by a salted key of the network address, and decides the account.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  const b = (await req.json().catch(() => null)) as Record<string, unknown> | null;
  if (!b || typeof b !== 'object') return NextResponse.json({ ok: false }, { status: 400, headers: H });
  try {
    const r = await capture(b);
    return NextResponse.json(r, { status: r.rateLimited ? 429 : 200, headers: H });
  } catch (e) {
    console.error('capture', e instanceof Error ? e.message.slice(0, 300) : e);
    return NextResponse.json({ ok: false }, { status: 200, headers: H });
  }
}
