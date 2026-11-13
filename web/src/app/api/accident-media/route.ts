import { NextResponse } from 'next/server';
import { storage } from '@/integrations/storage';
import { rpc } from '@/lib/db/repo';
import { realUser } from '@/server/portal/data';
import { UUID } from '@/features/returns/claim';
import { mediaKind, ACCIDENT_MEDIA_MAX } from '@/features/accident-card/report';
import { foreignOrigin } from '@/lib/security/same-origin';

// One photo or video of a renter's accident report (release 35, migration 0912): the renter of the booking only, from the
// camera roll (photos are made smaller on the phone first; a video goes as it is, up to 25 MB). Private storage; the report
// that lists the keys checks again that each belongs to this booking.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const SR = { role: 'service_role' as const, skipViewAs: true };

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const form = await req.formData().catch(() => null);
  const booking = String(form?.get('booking') ?? '');
  if (!UUID.test(booking)) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 400, headers: H });
  try { await rpc('server_renter_accidents' as never, { p_booking: booking, p_by: user.id } as never, SR); }
  catch { return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H }); }
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > ACCIDENT_MEDIA_MAX) return NextResponse.json({ ok: false, message: 'Each photo or video must be under 25 MB.' }, { status: 400, headers: H });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const k = mediaKind(bytes);
  if (!k) return NextResponse.json({ ok: false, message: 'That file is not a photo or a video.' }, { status: 400, headers: H });
  const key = `bookings/${booking}/accident/${crypto.randomUUID()}.${k.ext}`;
  await (await storage()).put('condition-photos', key, bytes, k.mime);
  return NextResponse.json({ ok: true, bucket: 'condition-photos', path: key, video: k.video }, { headers: H });
}
