'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { storage } from '@/integrations/storage';
import { readToken, sha256Hex } from '@/server/links';

// An additional driver's licence on their own signing link (migration 0130): no account, the signed token names their
// signer row. The photo is checked (a JPEG or PNG under 10 MB), stored privately and registered for staff review.
type R<T = unknown> = ActionResult<T>;
const SR = { role: 'service_role' as const };
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : String(e) });

async function signer(token: string): Promise<string> {
  const t = await readToken<{ s: string; v?: number }>('driver-sign', token);
  if (!t || (await rpc('server_driver_link_valid', { p_signer: t.s, p_version: t.v ?? 1 }, SR)) !== true) throw new Error('This link has expired. Ask the renter to send a new one.');
  return t.s;
}

export async function driverLicenceUpload(token: string, form: FormData): Promise<R> {
  try {
    const s = await signer(token);
    const kind = String(form.get('kind') ?? ''); const file = form.get('file');
    if (!['licence_front', 'licence_back', 'selfie'].includes(kind)) return fail('Unknown upload.');
    if (!(file instanceof Blob) || file.size === 0 || file.size > 10 * 1024 * 1024) return fail('The photo must be under 10 MB.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
    if (!jpg && !png) return fail('That file is not a photo.');
    const key = `drivers/${s}/${kind}-${crypto.randomUUID()}.${jpg ? 'jpg' : 'png'}`;
    const st = await storage();
    await st.put('identity', key, bytes, jpg ? 'image/jpeg' : 'image/png');
    try {
      await rpc('server_driver_register_upload', { p_signer: s, p_kind: kind, p_storage_path: key, p_sha256: await sha256Hex(bytes), p_mime_type: jpg ? 'image/jpeg' : 'image/png' }, SR);
    } catch (e) { await st.remove('identity', key).catch(() => undefined); throw e; }
    revalidatePath(`/sign/driver/${token}`);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export async function driverLicenceSave(token: string, d: { licence_number: string; licence_issuer: string; licence_expiry: string }): Promise<R> {
  try {
    const s = await signer(token);
    await rpc('server_driver_save_licence', { p_signer: s, p: { licence_number: d.licence_number, licence_issuer: d.licence_issuer, licence_expiry: d.licence_expiry } }, SR);
    revalidatePath(`/sign/driver/${token}`);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
