import { NextResponse } from 'next/server';
import { loadFeed } from '@/server/partner-feed';
import { renderWidget } from '@/features/partner-crm/widget';

// The inventory widget a partner drops into a GoHighLevel funnel or site as an iframe (migration 0136): our cars with the
// partner rates and availability, each opening its booking link with the partner's code. No script. The Worker entry lets
// this path, and only this path, be framed by other sites (src/lib/security/csp.ts embeddable).
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ partner: string }> }) {
  const { partner } = await params;
  const f = await loadFeed(partner, new URL(req.url).searchParams.get('key'));
  const head = { 'cache-control': 'private, max-age=300', 'x-robots-tag': 'noindex, nofollow', 'content-type': 'text/html; charset=utf-8' };
  if (!f) return new NextResponse('<!doctype html><title>Not found</title><p>Not found.</p>', { status: 404, headers: head });
  return new NextResponse(renderWidget(f.cars, { title: `${f.site.name} cars`, siteName: f.site.name, photos: f.photos }), { headers: head });
}
