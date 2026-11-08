'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal, type Call } from '@/server/door';
import { sha256Hex } from '@/server/links';
import { cleanVin, VIN_RE } from '@/features/vin/vin';
import { VIN_LIST_MAX } from '@/features/onboarding/vin-list';

// Release 34, part P (migrations 0821 to 0825): onboarding photos replaced, removed and reviewed; the government forms
// made again; cars from a VIN list. The owner, staff and an Admin use the same calls; the database decides who may.
type R<T = unknown> = ActionResult<T>;
const SR = { role: 'service_role' as const };
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const again = (paths: string[]) => { for (const p of paths) if (typeof p === 'string' && p.startsWith('/')) revalidatePath(p); };

async function me(): Promise<{ id: string; aal: 'aal1' | 'aal2' | null; doCall: Call; readCall: Call }> {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  const va = !roles.admin && !!roles.va;
  return { id: user.id, aal: await sessionAal(), doCall: va ? 'va_do' : 'ops_do', readCall: va ? 'va_read' : 'ops_read' };
}

type Photo = { id: string; vehicle_id: string; kind: string };
const TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };
function magic(b: Uint8Array): string | null {
  if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) return 'application/pdf';
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'image/png';
  return null;
}

/** form: document_id, owner_id, file (a photo re-encoded in the browser, or a PDF), paths (JSON). The new photo waits for review. */
export async function onboardingPhotoReplace(form: FormData): Promise<R<{ document_id: string; back_to_review: boolean }>> {
  try {
    const u = await me();
    const docId = String(form.get('document_id') ?? '');
    const ownerId = String(form.get('owner_id') ?? '');
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose the new photo or PDF.', fieldErrors: { file: 'Choose the new photo or PDF.' } };
    if (file.size > 10_000_000) return { ok: false, code: 'invalid', message: 'The file must be under 10 MB.', fieldErrors: { file: 'The file must be under 10 MB.' } };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const mime = magic(bytes);
    if (!mime) return { ok: false, code: 'invalid', message: 'Use a photo (JPEG or PNG) or a PDF.', fieldErrors: { file: 'Use a photo (JPEG or PNG) or a PDF.' } };
    // the photo, read with the viewer's rights: the database refuses one they may not change
    const photos = await door<Photo[]>(u.id, u.readCall, 'onboarding_photos', { owner_id: ownerId }, u.aal);
    const d = photos.find((x) => x.id === docId);
    if (!d) return fail(new Error('This photo was already replaced or removed. Reload the page.'));
    const key = `owners/${ownerId}/vehicles/${d.vehicle_id}/${d.kind}-${crypto.randomUUID()}.${TYPES[mime]}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('documents', key, bytes, mime);
    try {
      const r = await door<{ document_id: string; back_to_review: boolean }>(u.id, u.doCall, 'onboarding_photo_replace', { document_id: docId, path: key, sha256: await sha256Hex(bytes), mime }, u.aal);
      again(JSON.parse(String(form.get('paths') ?? '[]')) as string[]);
      return { ok: true, data: r };
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
  } catch (e) { return fail(e); }
}

/** Staff: a first photo for the owner's car (form: vehicle_id, owner_id, kind, file, paths); 0067's staff_vehicle_document files it. */
export async function onboardingPhotoAdd(form: FormData): Promise<R> {
  try {
    const u = await me();
    const vehicleId = String(form.get('vehicle_id') ?? '');
    const ownerId = String(form.get('owner_id') ?? '');
    const kind = String(form.get('kind') ?? '');
    if (!['ownership_permit', 'owner_insurance_proof', 'finance_party_permission'].includes(kind)) return fail(new Error('Choose what the photo is.'));
    if (!/^[0-9a-f-]{36}$/.test(vehicleId) || !/^[0-9a-f-]{36}$/.test(ownerId)) return fail(new Error('Choose the car.'));
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0 || file.size > 10_000_000) return fail(new Error('Choose a photo or PDF under 10 MB.'));
    const bytes = new Uint8Array(await file.arrayBuffer());
    const mime = magic(bytes);
    if (!mime) return fail(new Error('Use a photo (JPEG or PNG) or a PDF.'));
    const key = `owners/${ownerId}/vehicles/${vehicleId}/${kind}-${crypto.randomUUID()}.${TYPES[mime]}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('documents', key, bytes, mime);
    try {
      await door(u.id, u.doCall, 'staff_vehicle_document', { vehicle_id: vehicleId, kind, path: key, sha256: await sha256Hex(bytes), mime }, u.aal);
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
    again(JSON.parse(String(form.get('paths') ?? '[]')) as string[]);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export async function onboardingPhotoRemove(documentId: string, reason: string, paths: string[] = []): Promise<R> {
  try {
    const u = await me();
    const r = await door(u.id, u.doCall, 'onboarding_photo_remove', { document_id: documentId, reason: reason.trim() || null }, u.aal);
    again(paths);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

export async function onboardingPhotoReview(documentId: string, decision: 'approved' | 'rejected', note: string, paths: string[] = []): Promise<R> {
  try {
    const u = await me();
    const r = await door(u.id, u.doCall, 'onboarding_photo_review', { document_id: documentId, decision, note: note.trim() || null }, u.aal);
    again(paths);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** Admin: every form the car needs, made again now from what is on file (a form signed or filed is kept). */
export async function governmentFormsMakeAgain(vehicleId: string, paths: string[] = []): Promise<R<{ made: number; forms: Array<{ form_code: string; made: boolean; why?: string }> }>> {
  try {
    const u = await me();
    const r = await door<{ made: number; forms: Array<{ form_code: string; made: boolean; why?: string }> }>(u.id, 'ops_do', 'government_forms_make_again', { vehicle_id: vehicleId }, u.aal);
    again(paths);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- cars from a VIN list
export interface VinRow { vin: string; ok: boolean; why?: string; year?: number; make?: string; model?: string; trim?: string; title_status?: string; finance_party_name?: string }
export interface VinListResult { preview: boolean; rows: VinRow[]; good: number; bad: number; application_number?: string; vehicles?: Array<{ vehicle_id: string; vin: string }> }

/** The preview: each VIN decoded once with the app's decoder (recorded, so it is never decoded twice), then checked by the database. */
export async function vinListPreview(ownerId: string, vins: string[]): Promise<R<VinListResult>> {
  try {
    const u = await me();
    const list = vins.map((v) => cleanVin(v)).slice(0, VIN_LIST_MAX);
    if (!list.length) return { ok: false, code: 'invalid', message: 'Paste or upload at least one VIN.', fieldErrors: { vins: 'Paste or upload at least one VIN.' } };
    const { decodeVin } = await import('@/integrations/vin');
    const todo = [...new Set(list.filter((v) => VIN_RE.test(v)))];
    // the decoder, five at a time; a VIN already decoded (or failed in the last hour) is not asked again
    for (let i = 0; i < todo.length; i += 5) {
      await Promise.all(todo.slice(i, i + 5).map(async (vin) => {
        const f = (await rpc('server_vin_facts', { p_vin: vin }, SR)) as unknown as { decode: unknown; decode_failed_at?: string | null; check_ok?: boolean };
        const recent = f.decode_failed_at && Date.now() - new Date(f.decode_failed_at).getTime() < 3_600_000;
        if (f.decode || recent || f.check_ok === false) return;
        const d = await decodeVin(vin).catch(() => null);
        if (d) await rpc('server_record_vin_decode', { p_vin: vin, p_provider: d.provider, p_output: d.result as unknown as Json }, SR).catch(() => undefined);
      }));
    }
    const r = await door<VinListResult>(u.id, u.doCall, 'owner_add_vins', { owner_id: ownerId, cars: list.map((vin) => ({ vin })), preview: true }, u.aal);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** Every good car made in one step (one application); the rows say which were not made and why. */
export async function vinListCreate(ownerId: string, rows: Array<{ vin: string; title_status?: string; finance_party_name?: string }>, paths: string[] = []): Promise<R<VinListResult>> {
  try {
    const u = await me();
    const r = await door<VinListResult>(u.id, u.doCall, 'owner_add_vins', { owner_id: ownerId, cars: rows.slice(0, VIN_LIST_MAX), preview: false }, u.aal);
    again([...paths, '/owner', '/owner/vehicles', '/admin/owners', '/admin/applications']);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}
