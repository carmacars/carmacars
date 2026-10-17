'use server';
import { revalidatePath } from 'next/cache';
import { randomUUID } from 'node:crypto';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { assertAdmin } from '@/server/admin/data';
import { door, sessionAal } from '@/server/door';

// Admin > Settings > Sample photos and Admin access (migration 0054). The database checks every call again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const PUBLIC = ['/cars', '/cars/[slug]', '/', '/rent/[hub]'];

async function putPublic(key: string, bytes: Uint8Array, type: string) {
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  await s.put('vehicle-public', key, bytes, type);
  if (s.name === 'local') {
    // the local public bucket is served from public/_local (see README, "The local stack")
    const { mkdir, writeFile } = await import('node:fs/promises');
    const path = await import('node:path');
    const target = path.join(/* turbopackIgnore: true */ process.cwd(), 'public/_local/vehicle-public', key);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, bytes);
  }
}

/** A JPEG's width and height, read from its frame header (no image library in the Worker). */
function jpegSize(b: Uint8Array): { width: number; height: number } | null {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) return null;
    const m = b[i + 1]!; const len = (b[i + 2]! << 8) | b[i + 3]!;
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { height: (b[i + 5]! << 8) | b[i + 6]!, width: (b[i + 7]! << 8) | b[i + 8]! };
    i += 2 + len;
  }
  return null;
}

/** A stock photo for the library: per make and model, make, or body type. JPEG or WebP, up to 4 MB. */
export async function uploadSamplePhoto(form: FormData): Promise<R<{ id: string }>> {
  try {
    const admin = await assertAdmin();
    const file = form.get('file');
    const make = String(form.get('make') ?? '').trim(); const model = String(form.get('model') ?? '').trim(); const body = String(form.get('body_type') ?? '').trim();
    const fe: Record<string, string> = {};
    if (!(file instanceof File) || file.size === 0) fe.file = 'Choose a photo.';
    else if (file.size > 4_000_000) fe.file = 'The photo must be under 4 MB.';
    if (!make && !body) fe.body_type = 'Choose a body type, or type a make.';
    if (model && !make) fe.make = 'A model needs its make.';
    if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
    const f = file as File;
    const bytes = new Uint8Array(await f.arrayBuffer());
    const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8;
    const webp = String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP';
    if (!jpeg && !webp) return { ok: false, code: 'invalid', message: 'Use a JPEG or WebP photo.', fieldErrors: { file: 'Use a JPEG or WebP photo.' } };
    const key = `samples/${randomUUID()}.${jpeg ? 'jpg' : 'webp'}`;
    await putPublic(key, bytes, jpeg ? 'image/jpeg' : 'image/webp');
    const size = jpeg ? jpegSize(bytes) : null;
    const r = await door<{ id: string }>(admin.id, 'ops_do', 'sample_photo_save', { make, model, body_type: body, path: key, alt: String(form.get('alt') ?? '').trim(),
      width: size?.width ?? null, height: size?.height ?? null }, await sessionAal());
    revalidatePath('/admin/settings/sample-photos'); for (const p of PUBLIC) revalidatePath(p);
    return { ok: true, data: { id: r.id } };
  } catch (e) { return fail(e); }
}

export async function setSamplePhotoActive(id: string, active: boolean): Promise<R<null>> {
  try {
    const admin = await assertAdmin();
    await door(admin.id, 'ops_do', 'sample_photo_save', { id, active }, await sessionAal());
    revalidatePath('/admin/settings/sample-photos'); for (const p of PUBLIC) revalidatePath(p);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export async function deleteSamplePhoto(id: string): Promise<R<null>> {
  try {
    const admin = await assertAdmin();
    const r = await door<{ path: string }>(admin.id, 'ops_do', 'sample_photo_delete', { id }, await sessionAal());
    try { const { storage } = await import('@/integrations/storage'); await (await storage()).remove('vehicle-public', r.path); } catch (e) { console.error('sample photo file', e); }
    revalidatePath('/admin/settings/sample-photos'); for (const p of PUBLIC) revalidatePath(p);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

/** The addresses that may hold the Admin role (one per line). */
export async function saveAdminAccess(text: string): Promise<R<null>> {
  try {
    const admin = await assertAdmin();
    const emails = text.split(/[\s,;]+/).map((x) => x.trim().toLowerCase()).filter(Boolean);
    if (!emails.length) return { ok: false, code: 'invalid', message: 'Keep at least one Admin address.', fieldErrors: { emails: 'Keep at least one Admin address.' } };
    await door(admin.id, 'ops_do', 'admin_access_save', { emails }, await sessionAal());
    revalidatePath('/admin/settings/staff');
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
