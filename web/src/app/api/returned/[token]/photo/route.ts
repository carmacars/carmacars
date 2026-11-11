import { NextResponse } from 'next/server';
import { storage } from '@/integrations/storage';
import { claimPhotoKey, MAX_PHOTO_BYTES } from '@/features/returns/claim';
import { readClaim } from '@/features/returns/server';
import { imageSniff } from '@/lib/file-sniff';

// One photo of the renter's "I've returned the car" report (migration 0532), by the booking's link (no sign-in: the link
// is the key). The browser made it a JPEG and smaller first; here it must be a JPEG or PNG under 8 MB, and the booking
// must still be out with no report waiting. The file goes to private storage under bookings/<id>/return-claim/; the
// report itself (POST /api/returned/<token>) lists the keys, and the database accepts only keys of this booking.
export const dynamic = 'force-dynamic';

export async function POST(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const c = await readClaim((await params).token);
  if (!c) return NextResponse.json({ ok: false, message: 'This link is not valid.' }, { status: 404 });
  if (!c.can_report) return NextResponse.json({ ok: false, message: 'This booking has no return to report.' }, { status: 409 });
  const form = await req.formData().catch(() => null);
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX_PHOTO_BYTES) return NextResponse.json({ ok: false, message: 'Each photo must be under 8 MB.' }, { status: 400 });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const { jpg, png } = imageSniff(bytes);
  if (!jpg && !png) return NextResponse.json({ ok: false, message: 'That file is not a photo.' }, { status: 400 });
  const key = claimPhotoKey(c.booking_id, crypto.randomUUID(), png);
  await (await storage()).put('condition-photos', key, bytes, png ? 'image/png' : 'image/jpeg');
  return NextResponse.json({ ok: true, bucket: 'condition-photos', path: key }, { headers: { 'cache-control': 'no-store' } });
}
