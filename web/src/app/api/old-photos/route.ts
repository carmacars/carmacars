import { NextResponse } from 'next/server';
import { storage } from '@/integrations/storage';
import { door } from '@/server/door';
import { realUser } from '@/server/portal/data';
import { MAX_PHOTO_BYTES, UUID } from '@/features/returns/claim';
import { imageSniff } from '@/lib/file-sniff';
import { foreignOrigin } from '@/lib/security/same-origin';

// Add old photos (5185): one photo of a past check-in or check-out, made a standard JPEG on the phone first. The database
// says first whether this person may add to that booking and whether this upload (the phone's key) is attached already: a
// retry after a lost answer is answered "done" and stores nothing. Then the bytes go to private storage under a key the
// server makes, and the photo is attached to the report "added later" with its capture time.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const no = (message: string, status: number) => NextResponse.json({ ok: false, message }, { status, headers: H });
const words = (e: unknown) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not permitted.');

export async function POST(req: Request) {
  if (foreignOrigin(req.headers.get('origin'), req.headers.get('host'), req.headers.get('sec-fetch-site'))) return no('Not permitted.', 403);
  const user = await realUser();
  if (!user) return no('Sign in first.', 401);
  const form = await req.formData().catch(() => null);
  const booking = String(form?.get('booking') ?? '');
  const kind = String(form?.get('kind') ?? '');
  const key = String(form?.get('key') ?? '');
  if (!UUID.test(booking) || !UUID.test(key) || !['pickup', 'return'].includes(kind)) return no('Not permitted.', 400);
  let gate: { booking_id: string; duplicate: boolean };
  try { gate = await door(user.id, 'ops_read', 'old_photo_gate', { booking, kind, key }); } catch (e) { return no(words(e), 403); }
  if (gate.duplicate) return NextResponse.json({ ok: true, duplicate: true }, { headers: H });
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX_PHOTO_BYTES) return no('Each photo must be under 8 MB.', 400);
  const bytes = new Uint8Array(await file.arrayBuffer());
  const { jpg, png } = imageSniff(bytes);
  if (!jpg && !png) return no('That file is not a photo.', 400);
  const path = `bookings/${gate.booking_id}/old/${crypto.randomUUID()}.${png ? 'png' : 'jpg'}`;
  const s = await storage();
  await s.put('condition-photos', path, bytes, png ? 'image/png' : 'image/jpeg');
  const num = (k: string) => { const v = Number(form?.get(k)); return Number.isFinite(v) && v > 0 ? Math.round(v) : null; };
  try {
    const r = await door<{ duplicate: boolean; seq: number }>(user.id, 'ops_do', 'old_photo_attach',
      { booking, kind, key, path, taken_at: String(form?.get('taken_at') ?? '') || null, width: num('width'), height: num('height') });
    // a second upload of the same key that raced the first: the stored copy is not needed
    if (r.duplicate) await s.remove('condition-photos', path).catch(() => undefined);
    return NextResponse.json({ ok: true, duplicate: r.duplicate, seq: r.seq }, { headers: H });
  } catch (e) {
    await s.remove('condition-photos', path).catch(() => undefined);
    return no(words(e), 400);
  }
}
