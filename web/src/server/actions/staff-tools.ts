'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';

// The staff tools of migration 0042 (toll reading, plate covering, official forms) through the staff door's ops
// calls: the same screens for an Admin and an assistant; the database decides who may do what (Finance and
// Admins read notices; Fleet, customer service and Admins edit listing photos; Admins map the official forms).
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

export type StaffRead = 'toll_read_context' | 'toll_read' | 'toll_read_queue' | 'toll_profiles' | 'ai_vision_gate' | 'photo_plate_context' | 'form_templates' | 'form_template_preview' | 'rental_form_preview';
export async function staffRead<T = Record<string, unknown>>(what: StaffRead, p: Record<string, unknown> = {}): Promise<R<T>> {
  try { const { user, aal } = await me(); return { ok: true, data: await door<T>(user.id, 'ops_read', what, p, aal) }; } catch (e) { return fail(e); }
}

export async function staffDo<T = Record<string, unknown>>(action: string, p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    const data = await door<T>(user.id, 'ops_do', action, p, aal);
    for (const x of refresh) revalidatePath(x);
    // a plate decision changes what the car's public page shows
    if (action === 'photo_plate_record') { revalidatePath('/cars/[slug]', 'page'); revalidatePath('/cars'); revalidatePath('/', 'layout'); }
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

const MAX = 15_000_000;
/** A notice or statement (PDF, JPEG, PNG or CSV) into the private documents bucket, filed for Finance. */
export async function uploadNotice(form: FormData): Promise<R<{ id: string }>> {
  try {
    const { user, aal } = await me();
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose a file.' };
    if (file.size > MAX) return { ok: false, code: 'invalid', message: 'The file must be under 15 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
    const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
    const png = bytes[0] === 0x89 && bytes[1] === 0x50;
    const csv = !pdf && !jpg && !png && /\.csv$/i.test(file.name) && !bytes.slice(0, 2048).some((b) => b === 0);
    if (!pdf && !jpg && !png && !csv) return { ok: false, code: 'invalid', message: 'Use a PDF, JPEG, PNG or CSV file.' };
    const [type, ext] = pdf ? ['application/pdf', 'pdf'] : jpg ? ['image/jpeg', 'jpg'] : png ? ['image/png', 'png'] : ['text/csv', 'csv'];
    const key = `tolls/${new Date().getUTCFullYear()}/${crypto.randomUUID()}.${ext}`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, bytes, type!);
    const r = await door<{ id: string }>(user.id, 'ops_do', 'toll_read_document', { storage_path: key, mime_type: type, sha256: await sha256Hex(bytes), title: String(form.get('title') ?? file.name).slice(0, 200) }, aal);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** An official fillable PDF for a registry form (Admin > Settings > Forms). The fields were read in the browser. */
export async function uploadFormTemplate(form: FormData): Promise<R<Record<string, unknown>>> {
  try {
    const { user, aal } = await me();
    const file = form.get('file');
    const code = String(form.get('form_code') ?? '');
    if (!/^[A-Za-z0-9-]{2,30}$/.test(code)) return { ok: false, code: 'invalid', message: 'Unknown form.' };
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose the PDF.' };
    if (file.size > MAX) return { ok: false, code: 'invalid', message: 'The file must be under 15 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) return { ok: false, code: 'invalid', message: 'That file is not a PDF.' };
    let fields: unknown;
    try { fields = JSON.parse(String(form.get('fields') ?? '[]')); } catch { return { ok: false, code: 'invalid', message: 'The fields could not be read.' }; }
    const key = `forms/templates/${code}/${crypto.randomUUID()}.pdf`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, bytes, 'application/pdf');
    const data = await door<Record<string, unknown>>(user.id, 'ops_do', 'form_template_upload', { form_code: code, file_key: key, sha256: await sha256Hex(bytes),
      page_count: Number(form.get('page_count') ?? 0) || null, file_name: file.name, fields, title: String(form.get('title') ?? '') || null }, aal);
    revalidatePath('/admin/settings/forms');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** Blind Spot's rental agreement (Admin > Settings > Forms, 0127): its blank PDF, into the private documents bucket with
 *  its SHA-256. It must open and be A4 (the boxes are measured on Blind Spot's form). A new upload waits to be checked. */
export async function uploadRentalForm(form: FormData): Promise<R<{ id: string; same: boolean }>> {
  try {
    const { user, aal } = await me();
    const file = form.get('file');
    const code = String(form.get('form_code') ?? '');
    if (!/^[A-Z0-9-]{2,30}$/.test(code)) return { ok: false, code: 'invalid', message: 'Unknown form.' };
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose the PDF.' };
    if (file.size > MAX) return { ok: false, code: 'invalid', message: 'The file must be under 15 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) return { ok: false, code: 'invalid', message: 'That file is not a PDF.' };
    const { PDFDocument } = await import('pdf-lib');
    let pages = 0;
    try {
      const doc = await PDFDocument.load(bytes, { updateMetadata: false });
      pages = doc.getPageCount();
      const { width, height } = doc.getPage(0).getSize();
      if (Math.abs(width - 595.28) > 2 || Math.abs(height - 841.89) > 2) return { ok: false, code: 'invalid', message: `This PDF is ${Math.round(width)} by ${Math.round(height)} points; Blind Spot's form is A4. Upload Blind Spot's own PDF.` };
    } catch { return { ok: false, code: 'invalid', message: 'This PDF could not be opened (it may be encrypted). Upload Blind Spot\'s own PDF.' }; }
    const key = `forms/templates/${code}/${crypto.randomUUID()}.pdf`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, bytes, 'application/pdf');
    const data = await door<{ id: string; same: boolean }>(user.id, 'ops_do', 'rental_form_upload', { form_code: code, file_key: key, sha256: await sha256Hex(bytes), page_count: pages, file_name: file.name }, aal);
    revalidatePath('/admin/settings/forms');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** The authorized company representative's signature for a per-booking form: a PNG (a transparent background is best).
 *  Until one is uploaded, the representative's name is written on the form in a script hand. */
export async function uploadRentalSignature(form: FormData): Promise<R<Record<string, unknown>>> {
  try {
    const { user, aal } = await me();
    const file = form.get('file');
    const code = String(form.get('form_code') ?? '');
    if (!/^[A-Z0-9-]{2,30}$/.test(code)) return { ok: false, code: 'invalid', message: 'Unknown form.' };
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose the image.' };
    if (file.size > 2_000_000) return { ok: false, code: 'invalid', message: 'The image must be under 2 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (![0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((v, i) => bytes[i] === v)) return { ok: false, code: 'invalid', message: 'Use a PNG image of the signature.' };
    const key = `forms/signatures/${code}/${crypto.randomUUID()}.png`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, bytes, 'image/png');
    const data = await door<Record<string, unknown>>(user.id, 'ops_do', 'rental_form_rep', { form_code: code, signature_key: key, signature_sha256: await sha256Hex(bytes) }, aal);
    revalidatePath('/admin/settings/forms');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
