import { NextResponse, type NextRequest } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import type { CarFacts } from '@/features/ads/listing';
import { bestPhotos } from '@/features/marketplace/kit';
import { photoUrl } from '@/lib/photo';
import { zip } from '@/lib/zip';

// A Marketplace kit's photos as one ZIP (migration 0410): the ten best, named 01.jpg to 10.jpg in posting order, so the
// listing form takes them in one pick (docs/runbooks/marketplace.md). Admin only; the database checks the Admin again.
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest, { params }: { params: Promise<{ vehicle: string }> }) {
  let admin;
  try { admin = await assertAdmin(); } catch { return new NextResponse('Not permitted', { status: 403 }); }
  const { vehicle } = await params;
  if (!/^[0-9a-f-]{36}$/.test(vehicle)) return new NextResponse('Unknown car', { status: 400 });
  const data = await door<{ cars: CarFacts[] }>(admin.id, 'admin_read', 'marketplace', {});
  const car = data.cars.find((c) => c.vehicle_id === vehicle);
  if (!car) return new NextResponse('Unknown car', { status: 404 });
  const photos = bestPhotos(car.photos);
  if (!photos.length) return new NextResponse('This car has no real photos yet', { status: 404 });
  const files: Array<{ name: string; data: Uint8Array }> = [];
  for (const [i, p] of photos.entries()) {
    const u = photoUrl(p.path);
    const r = await fetch(/^https?:\/\//.test(u) ? u : new URL(u, req.nextUrl.origin)).catch(() => null);
    if (!r?.ok) continue;
    const type = r.headers.get('content-type') ?? '';
    const ext = /png/.test(type) ? 'png' : /webp/.test(type) ? 'webp' : 'jpg';
    files.push({ name: `${String(i + 1).padStart(2, '0')}.${ext}`, data: new Uint8Array(await r.arrayBuffer()) });
  }
  if (!files.length) return new NextResponse('The photos could not be read', { status: 502 });
  const name = `carmacars-${(car.car_code ?? car.slug).toLowerCase().replace(/[^a-z0-9-]+/g, '-')}-marketplace.zip`;
  return new NextResponse(zip(files) as unknown as BodyInit, { headers: { 'content-type': 'application/zip', 'content-disposition': `attachment; filename="${name}"`, 'cache-control': 'no-store', 'x-robots-tag': 'noindex' } });
}
