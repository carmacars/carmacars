import { NextResponse, type NextRequest } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { sessionAal } from '@/server/door';
import { scenePhotos } from '@/server/marketing-photos';
import { photoZip } from '@/server/marketplace-zip';

// r35 S2 (1053): a car's newest marketing set (the photos in their scenes) as one ZIP, 01 first. The database checks the person
// may make marketing photos (Admin, Fleet, customer service, Sales).
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest, { params }: { params: Promise<{ vehicle: string }> }) {
  const user = await currentUser();
  if (!user) return new NextResponse('Not permitted', { status: 403 });
  const { vehicle } = await params;
  if (!/^[0-9a-f-]{36}$/.test(vehicle)) return new NextResponse('Unknown car', { status: 400 });
  const photos = await scenePhotos(user.id, vehicle, await sessionAal()).catch(() => null);
  if (!photos) return new NextResponse('Not permitted', { status: 403 });
  return photoZip({ vehicle_id: vehicle, car_code: null, slug: `car-${vehicle.slice(0, 8)}` } as Parameters<typeof photoZip>[0], photos, req.nextUrl.origin, '-scenes');
}
