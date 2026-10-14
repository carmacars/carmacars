import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';

// One listing photo from the capture screen (docs/blueprint/09-listing-pipeline.md section 4). The browser
// resized it (3000 px on the long side, JPEG); here the user's right to list this car is checked by the
// database (app.listing_capture), the bytes are checked to be a JPEG or PNG under 15 MB, the file goes to
// the private vehicle-originals bucket and is registered on the intake (a retake replaces the shot).
export const dynamic = 'force-dynamic';
const MAX = 15 * 1024 * 1024;

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const aal = await sessionAal();
  const form = await req.formData().catch(() => null);
  const file = form?.get('file');
  const intake = String(form?.get('intake') ?? '');
  const shot = String(form?.get('shot') ?? '');
  if (!/^[0-9a-f-]{36}$/.test(intake) || !/^[a-z][a-z0-9_]{1,40}$/.test(shot)) return NextResponse.json({ ok: false, message: 'Unknown photo.' }, { status: 400 });
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX) return NextResponse.json({ ok: false, message: 'The photo must be under 15 MB.' }, { status: 400 });
  let cap: { vehicle_id: string; may_upload: boolean };
  try {
    cap = await door<{ vehicle_id: string; may_upload: boolean }>(user.id, 'ops_read', 'listing_capture', { intake }, aal);
  } catch {
    return NextResponse.json({ ok: false, message: 'You cannot add photos to this listing.' }, { status: 403 });
  }
  if (!cap.may_upload) return NextResponse.json({ ok: false, message: 'This listing no longer takes photos.' }, { status: 409 });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (!jpg && !png) return NextResponse.json({ ok: false, message: 'That file is not a photo (JPEG or PNG).' }, { status: 400 });
  const type = jpg ? 'image/jpeg' : 'image/png';
  const key = `vehicles/${cap.vehicle_id}/original/${intake}/${shot}-${crypto.randomUUID().slice(0, 8)}.${jpg ? 'jpg' : 'png'}`;
  await (await storage()).put('vehicle-originals', key, bytes, type);
  const num = (k: string) => { const v = Number(form?.get(k)); return Number.isInteger(v) && v > 0 && v < 20000 ? v : null; };
  try {
    // the photo's fingerprint: the same image on another listed car is a possible duplicate (migration 0040)
    const r = await door<{ photo_id: string; missing: string[]; complete: boolean; state: string; similar?: number }>(user.id, 'ops_do', 'listing_upload',
      { intake, shot_type: shot, original_path: key, width: num('width'), height: num('height'), byte_size: bytes.length, mime_type: type, sha256: await sha256Hex(bytes) }, aal);
    return NextResponse.json({ ok: true, ...r });
  } catch (e) {
    await (await storage()).remove('vehicle-originals', key).catch(() => undefined);
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The photo could not be saved.' }, { status: 422 });
  }
}
