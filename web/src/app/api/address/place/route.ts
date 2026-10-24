import { NextResponse } from 'next/server';
import { maps } from '@/integrations/maps';

// The chosen suggestion in its parts (migration 0130): street, unit, city, province, postal code and country, for the
// forms that keep an address field by field. One Place Details call closes the suggestion's session (the same token),
// counted against the daily cap; over the cap the answer is empty and the person types the parts.
export const dynamic = 'force-dynamic';
export async function GET(req: Request) {
  const u = new URL(req.url);
  const id = u.searchParams.get('id') ?? '';
  const s = u.searchParams.get('s') ?? '';
  if (!/^[A-Za-z0-9_-]{2,300}$/.test(id)) return NextResponse.json({ place: null });
  const p = await (await maps()).place(id, /^[A-Za-z0-9_-]{8,64}$/.test(s) ? s : crypto.randomUUID());
  return NextResponse.json({ place: p ? { id: p.id, label: p.label, parts: p.parts ?? null } : null }, { headers: { 'cache-control': 'private, max-age=300' } });
}
