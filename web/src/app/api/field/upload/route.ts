import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';

// A photo or a signature from the field checklist (06-field.md section 6). The phone resized it; here the
// job is checked to be the user's, the bytes are checked to be a JPEG or PNG under 8 MB, the file goes to
// private storage under bookings/{booking}/{pickup|return}/{seq}-{shot}, and a photo of the photo set is
// registered on the Condition Report (a retake replaces the shot). Signatures and late-damage close-ups
// are stored and their key returned.
export const dynamic = 'force-dynamic';
const MAX = 8 * 1024 * 1024;
const SHOT = /^[a-z_]{2,40}$/;

type Job = { job: { id: string; booking_id: string | null; vehicle_id: string }; report_kind: string | null };

export async function POST(req: Request) {
  // same-origin only: the session cookie must not be usable from another site
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const roles = await rolesOf(user.id);
  // field staff, and the staff who check a car out or in from the booking page (0130: the database checks the job is theirs)
  if (!roles.field && !roles.admin && !roles.va) return NextResponse.json({ ok: false, message: 'Only staff may upload here.' }, { status: 403 });
  const aal = await sessionAal();
  const form = await req.formData().catch(() => null);
  const file = form?.get('file');
  const jobId = String(form?.get('job') ?? '');
  const shot = String(form?.get('shot') ?? '');
  const seq = Number(form?.get('seq') ?? 0);
  const mode = form?.get('mode') === 'raw' ? 'raw' : 'photo';
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX) return NextResponse.json({ ok: false, message: 'The photo must be under 8 MB.' }, { status: 400 });
  if (!/^[0-9a-f-]{36}$/.test(jobId) || !SHOT.test(shot) || !(Number.isInteger(seq) && seq >= 0 && seq < 1000)) return NextResponse.json({ ok: false, message: 'Unknown photo.' }, { status: 400 });
  const j = await door<Job | null>(user.id, 'field_read', 'job', { id: jobId }, aal).catch(() => null);
  if (!j) return NextResponse.json({ ok: false, message: 'That job is not one of yours.' }, { status: 404 });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (!jpg && !png) return NextResponse.json({ ok: false, message: 'That file is not a photo.' }, { status: 400 });
  const leg = j.report_kind ?? 'other';
  const owner = j.job.booking_id ? `bookings/${j.job.booking_id}` : `vehicles/${j.job.vehicle_id}`;
  const bucket = shot === 'licence' ? 'identity' : 'condition-photos';
  const key = `${owner}/${leg}/${mode === 'raw' ? `${shot}-${crypto.randomUUID().slice(0, 8)}` : `${seq}-${shot}`}.${jpg ? 'jpg' : 'png'}`;
  await (await storage()).put(bucket, key, bytes, jpg ? 'image/jpeg' : 'image/png');
  if (mode === 'raw') return NextResponse.json({ ok: true, key });
  const meta = (k: string) => { const v = form?.get(k); return typeof v === 'string' && v ? v : null; };
  const coord = (k: string, lim: number) => { const n = Number(meta(k)); return meta(k) !== null && Number.isFinite(n) && Math.abs(n) <= lim ? n : null; };
  const photo = { seq, shot, storage_path: key, storage_bucket: bucket, damage_label: meta('damage_label'), device_taken_at: meta('taken_at'), latitude: coord('latitude', 90), longitude: coord('longitude', 180),
    width: meta('width') ? Number(meta('width')) : null, height: meta('height') ? Number(meta('height')) : null,
    quality_flags: (() => { try { return meta('flags') ? JSON.parse(meta('flags')!) as unknown : null; } catch { return null; } })() };
  try {
    const r = await door<{ problems: string[] }>(user.id, 'field_do', 'save_report', { job: jobId, report: { photos: [photo] } }, aal);
    return NextResponse.json({ ok: true, key, problems: r.problems });
  } catch (e) {
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The photo could not be saved.' }, { status: 422 });
  }
}
