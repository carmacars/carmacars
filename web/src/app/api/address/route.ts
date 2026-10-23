import { NextResponse } from 'next/server';
import { maps } from '@/integrations/maps';

// Address suggestions for the forms. The maps key stays on the server. Short responses, cached briefly.
export const dynamic = 'force-dynamic';
export async function GET(req: Request) {
  const u = new URL(req.url);
  const q = (u.searchParams.get('q') ?? '').slice(0, 120);
  const s = u.searchParams.get('s') ?? '';
  // 3 characters at least (the form asks from 3 too): every Google call counts against the daily cap (0113)
  if (q.trim().length < 3) return NextResponse.json({ items: [] });
  const items = await (await maps()).autocomplete(q, /^[A-Za-z0-9_-]{8,64}$/.test(s) ? s : crypto.randomUUID());
  return NextResponse.json({ items }, { headers: { 'cache-control': 'private, max-age=60' } });
}
