'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';
import { storage } from '@/integrations/storage';
import { cleanVin, trimOf, VIN_RE } from '@/features/vin/vin';
import { vinFacts } from '@/server/actions/vin';

// A car's registration in Admin (migration 0237): the VIN (decoded again with vPIC for the body style and trim), the year,
// the body style, the permit number and the plate sticker expiry; and the car's documents, the ownership permit first.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : String(e) });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

export interface RegistrationInput { vehicle_id: string; vin?: string; year?: string; body_type?: string; permit_number?: string; sticker_expires_on?: string }
export async function saveRegistration(i: RegistrationInput): Promise<R<{ vin_changed: boolean; decoded: boolean }>> {
  try {
    const { user, aal } = await me();
    const p: Record<string, unknown> = { vehicle_id: i.vehicle_id };
    let decoded = false;
    const vin = cleanVin(i.vin ?? '');
    if (vin) {
      if (!VIN_RE.test(vin)) return { ok: false, code: 'invalid', message: 'A VIN is 17 letters and digits, never I, O or Q.', fieldErrors: { vin: 'A VIN is 17 letters and digits, never I, O or Q.' } };
      p.vin = vin;
      // decoded again (recorded once per VIN): the body style and trim when the form leaves them empty
      const f = await vinFacts(vin).catch(() => null);
      const d = f && f.ok ? f.data.decode : null;
      if (d) {
        decoded = true;
        if (!i.body_type?.trim() && d.body_class) p.body_type = d.body_class;
        const t = trimOf(d.trim ?? '');
        if (t) p.trim = t;
        if (!i.year?.trim() && d.year) p.year = d.year;
      }
    }
    if (i.year?.trim()) p.year = i.year.trim();
    if (i.body_type !== undefined && i.body_type.trim()) p.body_type = i.body_type.trim();
    if (i.permit_number !== undefined) p.permit_number = i.permit_number;
    if (i.sticker_expires_on !== undefined) p.sticker_expires_on = i.sticker_expires_on;
    const r = await door<{ vin_changed: boolean }>(user.id, 'ops_do', 'vehicle_registration_save', p, aal);
    revalidatePath(`/admin/vehicles/${i.vehicle_id}`);
    return { ok: true, data: { vin_changed: r.vin_changed, decoded } };
  } catch (e) { return fail(e); }
}

export async function uploadVehicleDocument(form: FormData): Promise<R<{ document_id: string }>> {
  try {
    const { user, aal } = await me();
    const vehicle = String(form.get('vehicle') ?? ''); const kind = String(form.get('kind') ?? '');
    const file = form.get('file');
    if (!/^[0-9a-f-]{36}$/.test(vehicle) || !['ownership_permit', 'safety_certificate', 'owner_insurance_proof', 'other'].includes(kind)) return { ok: false, code: 'invalid', message: 'Unknown upload.' };
    if (!(file instanceof Blob) || file.size === 0 || file.size > 15 * 1024 * 1024) return { ok: false, code: 'invalid', message: 'The file must be under 15 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
    const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
    if (!jpg && !png && !pdf) return { ok: false, code: 'invalid', message: 'Upload a photo (JPG or PNG) or a PDF.' };
    const [ext, mime] = pdf ? ['pdf', 'application/pdf'] : jpg ? ['jpg', 'image/jpeg'] : ['png', 'image/png'];
    const key = `vehicles/${vehicle}/documents/${kind}-${crypto.randomUUID()}.${ext}`;
    const s = await storage();
    await s.put('documents', key, bytes, mime);
    try {
      const r = await door<{ document_id: string }>(user.id, 'ops_do', 'vehicle_document_register', { vehicle_id: vehicle, kind, path: key, mime, sha256: await sha256Hex(bytes),
        title: String(form.get('title') ?? '').trim() || undefined,
        ...(kind === 'safety_certificate' ? { number: String(form.get('number') ?? '').trim(), issued_on: String(form.get('issued_on') ?? ''), expires_on: String(form.get('expires_on') ?? '') } : {}) }, aal);
      revalidatePath(`/admin/vehicles/${vehicle}`);
      return { ok: true, data: r };
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
  } catch (e) { return fail(e); }
}
