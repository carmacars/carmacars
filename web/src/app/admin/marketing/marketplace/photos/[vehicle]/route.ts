import { NextResponse, type NextRequest } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import type { CarFacts } from '@/features/ads/listing';
import { bestPhotos } from '@/features/marketplace/kit';
import { photoZip } from '@/server/marketplace-zip';
import { scenePhotos } from '@/server/marketing-photos';

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
  // r35 S2 (1053): ?set=scenes gives the car's newest marketing set (its photos in their scenes) instead
  if (req.nextUrl.searchParams.get('set') === 'scenes') return photoZip(car, await scenePhotos(admin.id, vehicle).catch(() => []), req.nextUrl.origin, '-scenes');
  return photoZip(car, bestPhotos(car.photos), req.nextUrl.origin);
}
