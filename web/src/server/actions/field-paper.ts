'use server';
import { revalidatePath } from 'next/cache';
import { PDFDocument } from 'pdf-lib';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';

// The rental agreement signed on paper at the check-out (0144): field staff photograph each page with the phone camera,
// the pages become one PDF stored where paper signatures are kept, and the database records it as customer service
// records a paper signature (app.field_paper_signed checks the job is theirs and the booking waits for a signature).
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const MAX_PAGES = 12;
const MAX_BYTES = 12 * 1024 * 1024;

export async function fieldPaperScan(form: FormData): Promise<R<{ awaiting_signature: boolean }>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (!roles.field && !roles.admin && !roles.va) throw new Error('Only staff record a paper signature.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const job = String(form.get('job') ?? '');
    const booking = String(form.get('booking') ?? '');
    if (!/^[0-9a-f-]{36}$/.test(job) || !/^[0-9a-f-]{36}$/.test(booking)) return { ok: false, code: 'invalid', message: 'Unknown job.' };
    const files = form.getAll('page').filter((f): f is File => f instanceof File && f.size > 0);
    if (!files.length) return { ok: false, code: 'invalid', message: 'Take a photo of each page of the signed agreement.' };
    if (files.length > MAX_PAGES) return { ok: false, code: 'invalid', message: `At most ${MAX_PAGES} pages.` };
    const pdf = await PDFDocument.create();
    for (const f of files) {
      if (f.size > MAX_BYTES) return { ok: false, code: 'invalid', message: 'Each page must be under 12 MB.' };
      const bytes = new Uint8Array(await f.arrayBuffer());
      const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
      const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
      const isPdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
      if (isPdf) {
        const src = await PDFDocument.load(bytes);
        for (const pg of await pdf.copyPages(src, src.getPageIndices())) pdf.addPage(pg);
        continue;
      }
      if (!jpg && !png) return { ok: false, code: 'invalid', message: 'Use the camera (a photo) or a PDF for each page.' };
      const img = jpg ? await pdf.embedJpg(bytes) : await pdf.embedPng(bytes);
      // a Letter page, the photo fitted inside a small margin
      const W = 612, H = 792, M = 18;
      const s = Math.min((W - 2 * M) / img.width, (H - 2 * M) / img.height);
      const page = pdf.addPage([W, H]);
      page.drawImage(img, { x: (W - img.width * s) / 2, y: (H - img.height * s) / 2, width: img.width * s, height: img.height * s });
    }
    pdf.setTitle('Rental agreement signed on paper');
    pdf.setProducer('CarmaCars');
    const out = await pdf.save();
    // the agreement the renter signed: opened first when it never was (as Admin and customer service record a paper copy)
    const live = await rpc('server_signing_record', { p_booking: booking }, { role: 'service_role' }).catch(() => null);
    if (!live) {
      const { openAgreement } = await import('@/server/portal/agreement');
      await openAgreement(booking, user.id).catch(() => undefined);
    }
    const key = `paper/rental_agreement/${new Date().getUTCFullYear()}/${crypto.randomUUID()}.pdf`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('agreements', key, out, 'application/pdf');
    let r: { awaiting_signature?: boolean };
    try {
      r = await door<{ awaiting_signature?: boolean }>(user.id, 'field_do', 'paper_signed', {
        job, signer_name: String(form.get('signer_name') ?? '').trim() || null, pages: files.length,
        scan: { path: key, sha256: await sha256Hex(out), mime: 'application/pdf' } }, aal);
    } catch (e) { await s.remove('agreements', key).catch(() => undefined); throw e; }
    revalidatePath(`/field/jobs/${job}`);
    revalidatePath('/admin/bookings', 'layout');
    revalidatePath('/va/bookings', 'layout');
    return { ok: true, data: { awaiting_signature: Boolean(r.awaiting_signature) } };
  } catch (e) { return fail(e); }
}
