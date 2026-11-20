'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { imageSniff } from '@/lib/file-sniff';

// r48 FE (3190): a receipt, invoice, notice or photo uploaded for one fee line on the Money tab (Evidence). The file is
// checked to be a photo or a PDF under 15 MB, stored privately under evidence/<booking>/, and registered on the line by
// the database (app.fee_evidence_attach), which checks who may and checks the evidence again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : String(e) });
const KINDS = ['receipt', 'invoice', 'photo', 'notice', 'police_report', 'damage_closeup', 'other'];

export async function feeEvidenceUpload(form: FormData): Promise<R<{ evidence_status: string }>> {
  try {
    const user = await currentUser();
    if (!user) return fail('Sign in first.');
    const roles = await rolesOf(user.id);
    if (!roles.admin && !roles.va && !roles.field) return fail('Staff only.');
    const aal = await sessionAal();
    const booking = String(form.get('booking') ?? ''); const line = String(form.get('line') ?? ''); const kind = String(form.get('kind') ?? '');
    const note = String(form.get('note') ?? '').trim().slice(0, 2000);
    if (!/^[0-9a-f-]{36}$/.test(booking) || !/^[0-9a-f-]{36}$/.test(line) || !KINDS.includes(kind)) return fail('Unknown upload.');
    const file = form.get('file');
    if (!(file instanceof Blob) || file.size === 0) {
      if (!note) return fail('Choose a file or write a note.');
      const r = await door<{ evidence_status: string }>(user.id, 'ops_do', 'fee_evidence_attach', { line, kind: kind === 'photo' ? 'note' : kind, note }, aal);
      revalidatePath('/admin/bookings', 'layout'); revalidatePath('/staff/bookings', 'layout');
      return { ok: true, data: r };
    }
    if (file.size > 15 * 1024 * 1024) return fail('The file must be under 15 MB.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    const { jpg, png } = imageSniff(bytes);
    const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
    if (!jpg && !png && !pdf) return fail('Upload a photo (JPG or PNG) or a PDF.');
    const [ext, mime] = pdf ? ['pdf', 'application/pdf'] : jpg ? ['jpg', 'image/jpeg'] : ['png', 'image/png'];
    const key = `evidence/${booking}/${line}-${crypto.randomUUID()}.${ext}`;
    const s = await storage();
    await s.put('documents', key, bytes, mime);
    try {
      const r = await door<{ evidence_status: string }>(user.id, 'ops_do', 'fee_evidence_attach', { line, kind, note: note || undefined, path: key, mime, sha256: await sha256Hex(bytes) }, aal);
      revalidatePath('/admin/bookings', 'layout'); revalidatePath('/staff/bookings', 'layout');
      return { ok: true, data: r };
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
  } catch (e) { return fail(e); }
}
