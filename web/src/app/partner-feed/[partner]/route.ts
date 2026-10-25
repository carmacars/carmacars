import { NextResponse } from 'next/server';
import { loadFeed } from '@/server/partner-feed';
import { feedCsv, feedRow } from '@/features/partner-crm/mapping';

// A partner's read-only feed of our cars (migration 0147), JSON or CSV, for their CRM's imports and automations. The key
// is in the address (Admin > Settings > Partners shows it; New key ends the old one). Never a partner car.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ partner: string }> }) {
  const { partner } = await params;
  const u = new URL(req.url);
  const f = await loadFeed(partner, u.searchParams.get('key'));
  const head = { 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow' };
  if (!f) return new NextResponse('Not found', { status: 404, headers: head });
  const rows = f.cars.map((c) => feedRow(c, f.photos(c)));
  if (u.searchParams.get('format') === 'csv') {
    return new NextResponse(feedCsv(rows), { headers: { ...head, 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'inline; filename="carmacars-cars.csv"' } });
  }
  return NextResponse.json({ source: f.site.name, partner: f.partner, updated_at: new Date().toISOString(), currency: 'CAD', count: rows.length, cars: rows }, { headers: head });
}
