import { NextResponse } from 'next/server';
import { currentUser, findBooking } from '@/server/portal/data';
import { buildPass, walletReady } from '@/server/wallet';
import { env } from '@/lib/env';
import { getSettings } from '@/lib/site';

// "Add to Apple Wallet" on a confirmed booking (Release 22): the renter's own booking, signed in. 404 until Apple Wallet
// is set up (src/server/wallet.ts).
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ number: string }> }) {
  const { number } = await params;
  const user = await currentUser();
  if (!user || !walletReady()) return new NextResponse('Not found', { status: 404 });
  const b = await findBooking(user, number);
  if (!b || !['confirmed', 'on_rent'].includes(b.status)) return new NextResponse('Not found', { status: 404 });
  const s = await getSettings().catch(() => null);
  const pass = await buildPass({ number: b.booking_number, car: `${b.vehicle_year} ${b.vehicle_make} ${b.vehicle_model}`, pickup: b.pickup_at, ret: b.return_at,
    place: b.pickup_place ?? 'CarmaCars', returnPlace: b.return_place, phone: s?.phone_display ?? s?.phone ?? null, site: env().NEXT_PUBLIC_APP_URL });
  return new NextResponse(pass as unknown as BodyInit, { headers: { 'content-type': 'application/vnd.apple.pkpass', 'content-disposition': `attachment; filename="${b.booking_number}.pkpass"`, 'cache-control': 'private, no-store' } });
}
