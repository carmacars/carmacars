'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';
import { imageSniff } from '@/lib/file-sniff';

// R50 hotfix 2 (5143, 5144): receipt photos of an expense and ownership permits uploaded in bulk. Each file is checked by its
// bytes (a photo or a PDF, under 15 MB), stored in the private documents bucket under a key the server builds, then the
// database files it (the door's ops_do expense_log and permit_file decide who may and where it goes). A file stored for a
// call the database refuses is removed again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const MAX = 15_000_000;
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
type Stored = { path: string; mime: string; sha256: string };
async function store(file: unknown, folder: 'expenses' | 'permits'): Promise<Stored> {
  if (!(file instanceof Blob) || file.size === 0) throw new Error('Choose a photo or a PDF.');
  if (file.size > MAX) throw new Error('Each file must be under 15 MB.');
  const bytes = new Uint8Array(await file.arrayBuffer());
  const { jpg, png } = imageSniff(bytes);
  const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
  if (!jpg && !png && !pdf) throw new Error('Use a photo (JPEG or PNG) or a PDF.');
  const [ext, mime] = pdf ? ['pdf', 'application/pdf'] : jpg ? ['jpg', 'image/jpeg'] : ['png', 'image/png'];
  const path = `${folder}/${new Date().getUTCFullYear()}/${crypto.randomUUID()}.${ext}`;
  const { storage } = await import('@/integrations/storage');
  await (await storage()).put('documents', path, bytes, mime);
  return { path, mime, sha256: await sha256Hex(bytes) };
}
async function unstore(paths: string[]) {
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  await Promise.all(paths.map((p) => s.remove('documents', p).catch(() => undefined)));
}

/** An expense with its receipt photos (form: photos, and the fields as JSON in "expense"). */
export async function logExpense(form: FormData): Promise<R<{ id: string; payer: string; vehicle_name: string | null; total_cents: number }>> {
  const stored: Stored[] = [];
  try {
    const { user, aal } = await me();
    const files = form.getAll('photos');
    if (!files.length) return { ok: false, code: 'invalid', message: 'Add at least one photo of the receipt.' };
    if (files.length > 10) return { ok: false, code: 'invalid', message: 'At most 10 photos for one expense.' };
    let fields: Record<string, unknown>;
    try { fields = JSON.parse(String(form.get('expense') ?? '{}')) as Record<string, unknown>; } catch { return { ok: false, code: 'invalid', message: 'The expense could not be read.' }; }
    for (const f of files) stored.push(await store(f, 'expenses'));
    const data = await door<{ id: string; payer: string; vehicle_name: string | null; total_cents: number }>(user.id, 'ops_do', 'expense_log', { ...fields, photos: stored }, aal);
    for (const p of ['/admin/expenses', '/staff/expenses']) revalidatePath(p);
    return { ok: true, data };
  } catch (e) { await unstore(stored.map((s) => s.path)); return fail(e); }
}

/** One ownership permit file with what the permit reader read from it (vin, plate, read as JSON). */
export async function filePermit(form: FormData): Promise<R<{ upload: string; status: 'filed' | 'unmatched'; vehicle_name?: string; matched_by?: string; note?: string | null }>> {
  let stored: Stored | null = null;
  try {
    const { user, aal } = await me();
    const file = form.get('file');
    stored = await store(file, 'permits');
    let read: unknown = {};
    try { read = JSON.parse(String(form.get('read') ?? '{}')); } catch { read = {}; }
    const data = await door<{ upload: string; status: 'filed' | 'unmatched'; vehicle_name?: string; matched_by?: string; note?: string | null }>(user.id, 'ops_do', 'permit_file', {
      path: stored.path, mime: stored.mime, sha256: stored.sha256, file_name: file instanceof File ? file.name.slice(0, 200) : null,
      vin: String(form.get('vin') ?? '') || null, plate: String(form.get('plate') ?? '') || null, read }, aal);
    for (const p of ['/admin/ownership-documents', '/staff/ownership-documents']) revalidatePath(p);
    return { ok: true, data };
  } catch (e) { if (stored) await unstore([stored.path]); return fail(e); }
}
