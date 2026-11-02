import { NextResponse, type NextRequest } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import type { CarFacts } from '@/features/ads/listing';
import { bestPhotos } from '@/features/marketplace/kit';
import { variantPhotos, MAX_VARIANT } from '@/features/marketplace/variants';
import { photoZip } from '@/server/marketplace-zip';

// Sales > Marketing: one copy variant's photos as a ZIP (migration 0510), the variant's own cover first. The database
// checks the person is Sales or an Admin (va_read mp_team).
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest, { params }: { params: Promise<{ vehicle: string }> }) {
  const user = await currentUser();
  if (!user) return new NextResponse('Not permitted', { status: 403 });
  const { vehicle } = await params;
  const v = Number(req.nextUrl.searchParams.get('v') ?? '2');
  if (!/^[0-9a-f-]{36}$/.test(vehicle) || !Number.isInteger(v) || v < 2 || v > MAX_VARIANT) return new NextResponse('Unknown car', { status: 400 });
  const data = await door<{ cars: CarFacts[] }>(user.id, 'va_read', 'mp_team', { _va: 'sales' }, await sessionAal()).catch(() => null);
  if (!data) return new NextResponse('Not permitted', { status: 403 });
  const car = data.cars.find((c) => c.vehicle_id === vehicle);
  if (!car) return new NextResponse('Unknown car', { status: 404 });
  return photoZip(car, variantPhotos(bestPhotos(car.photos), v), req.nextUrl.origin, `-v${v}`);
}
