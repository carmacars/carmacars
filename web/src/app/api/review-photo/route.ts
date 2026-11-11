import { NextResponse } from 'next/server';
import { storage } from '@/integrations/storage';
import { realUser, findBooking } from '@/server/portal/data';
import { mediaKind } from '@/features/accident-card/report';

// r35a (1305): one photo for a renter's review of their rental (the renter of the booking only; a photo, made smaller on the
// phone first, up to 10 MB). Private storage under the booking; the review's photo list (server_review_photos_set) checks
// again that each key belongs to this booking.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const MAX = 10 * 1024 * 1024;

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const form = await req.formData().catch(() => null);
  const b = await findBooking(user, String(form?.get('number') ?? '')).catch(() => null);
  if (!b || !['returned', 'closed'].includes(b.status)) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX) return NextResponse.json({ ok: false, message: 'Each photo must be under 10 MB.' }, { status: 400, headers: H });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const k = mediaKind(bytes);
  if (!k || k.video) return NextResponse.json({ ok: false, message: 'That file is not a photo.' }, { status: 400, headers: H });
  const key = `bookings/${b.id}/review/${crypto.randomUUID()}.${k.ext}`;
  await (await storage()).put('condition-photos', key, bytes, k.mime);
  return NextResponse.json({ ok: true, path: key }, { headers: H });
}
