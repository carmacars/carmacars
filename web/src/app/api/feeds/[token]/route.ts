import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { photoUrls } from '@/features/partner-crm/mapping';
import { csv, row, shared, xml, type ChannelCar } from '@/features/channels/feed';

// A listing channel's inventory feed (migration 0216): /api/feeds/<token>?format=json|csv|xml. CarmaCars' own and
// co-hosted cars only, never a partner car. Each channel has its own key (Admin > Marketing > Listing channels; New key
// ends the old address). The database allows a set number of fetches an hour per channel; each answer is cached 15 minutes.
export const dynamic = 'force-dynamic';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Feed = { limited: boolean; retry_after?: number; channel: string; channel_name: string; cars: ChannelCar[]; site: { url: string; name: string; city: string } };

export async function GET(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const u = new URL(req.url);
  const format = (u.searchParams.get('format') ?? 'json').toLowerCase();
  const head = { 'x-robots-tag': 'noindex, nofollow' };
  if (!UUID.test(token) || !['json', 'csv', 'xml'].includes(format)) return new NextResponse('Not found', { status: 404, headers: { ...head, 'cache-control': 'no-store' } });
  const f = (await rpc('server_channel_feed', { p_token: token }, { role: 'service_role' }).catch(() => null)) as unknown as Feed | null;
  if (!f) return new NextResponse('Not found', { status: 404, headers: { ...head, 'cache-control': 'no-store' } });
  if (f.limited) return new NextResponse('Too many requests', { status: 429, headers: { ...head, 'retry-after': String(f.retry_after ?? 3600), 'cache-control': 'no-store' } });
  const s = await storage();
  const abs = (p: string) => (/^https?:\/\//.test(p) ? p : `${f.site.url}${p.startsWith('/') ? '' : '/'}${p}`);
  const rows = shared(f.cars).map((c) => row(c, f.channel, (p) => photoUrls([p], f.site.url, (x) => abs(s.publicUrl(x)))[0] ?? p));
  const cache = { ...head, 'cache-control': 'public, max-age=900, s-maxage=900' };
  if (format === 'csv') return new NextResponse(csv(rows), { headers: { ...cache, 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'inline; filename="carmacars-cars.csv"' } });
  if (format === 'xml') return new NextResponse(xml(rows, f.site), { headers: { ...cache, 'content-type': 'application/xml; charset=utf-8' } });
  return NextResponse.json({ source: f.site.name, channel: f.channel_name, updated_at: new Date().toISOString(), currency: 'CAD', count: rows.length, cars: rows }, { headers: cache });
}
