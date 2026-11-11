'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';

// Add a customer review (release 36, migration 2002): a review that arrived outside the site, entered as received by
// an Admin or customer service or sales staff, with an optional proof (a screenshot or a PDF, kept private). The
// database checks the person and every rule (the name as "First L.", no future date, no duplicate, the words kept).
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

export async function outsideReviewAdd(form: FormData): Promise<R<{ id: string }>> {
  let key: string | null = null;
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const aal = await sessionAal();
    const p: Record<string, unknown> = {};
    for (const k of ['reviewer_name', 'source', 'received_on', 'rating', 'body', 'vehicle_id']) p[k] = String(form.get(k) ?? '').trim();
    const file = form.get('proof');
    if (file instanceof Blob && file.size > 0) {
      if (file.size > 10 * 1024 * 1024) return fail('The proof must be under 10 MB.');
      const bytes = new Uint8Array(await file.arrayBuffer());
      const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
      const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
      const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
      if (!jpg && !png && !pdf) return fail('The proof is a screenshot (JPG or PNG) or a PDF.');
      const [ext, mime] = pdf ? ['pdf', 'application/pdf'] : jpg ? ['jpg', 'image/jpeg'] : ['png', 'image/png'];
      key = `outside-reviews/${crypto.randomUUID()}.${ext}`;
      await (await storage()).put('documents', key, bytes, mime);
      p.proof_path = key; p.proof_mime = mime;
    }
    const data = await door<{ id: string }>(user.id, 'ops_do', 'outside_review_add', p, aal);
    revalidatePath('/admin/reviews'); revalidatePath('/staff/review-requests');
    return { ok: true, data };
  } catch (e) {
    if (key) await (await storage()).remove('documents', key).catch(() => undefined);
    return fail(e);
  }
}
