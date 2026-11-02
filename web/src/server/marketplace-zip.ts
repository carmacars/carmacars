import 'server-only';
import { NextResponse } from 'next/server';
import type { AdPhoto, CarFacts } from '@/features/ads/listing';
import { photoUrl } from '@/lib/photo';
import { zip } from '@/lib/zip';

// A Marketplace kit's photos as one ZIP (migrations 0410 and 0510): named 01 to 10 in posting order (01 is the cover), so the
// listing form takes them in one pick. The callers check who may download them.
export async function photoZip(car: CarFacts, photos: AdPhoto[], origin: string, suffix = ''): Promise<NextResponse> {
  if (!photos.length) return new NextResponse('This car has no real photos yet', { status: 404 });
  const files: Array<{ name: string; data: Uint8Array }> = [];
  for (const [i, p] of photos.entries()) {
    const u = photoUrl(p.path);
    const r = await fetch(/^https?:\/\//.test(u) ? u : new URL(u, origin)).catch(() => null);
    if (!r?.ok) continue;
    const type = r.headers.get('content-type') ?? '';
    const ext = /png/.test(type) ? 'png' : /webp/.test(type) ? 'webp' : 'jpg';
    files.push({ name: `${String(i + 1).padStart(2, '0')}.${ext}`, data: new Uint8Array(await r.arrayBuffer()) });
  }
  if (!files.length) return new NextResponse('The photos could not be read', { status: 502 });
  const name = `carmacars-${(car.car_code ?? car.slug).toLowerCase().replace(/[^a-z0-9-]+/g, '-')}${suffix}-marketplace.zip`;
  return new NextResponse(zip(files) as unknown as BodyInit, { headers: { 'content-type': 'application/zip', 'content-disposition': `attachment; filename="${name}"`, 'cache-control': 'no-store', 'x-robots-tag': 'noindex' } });
}
