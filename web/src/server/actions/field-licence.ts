'use server';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { storage, type Bucket } from '@/integrations/storage';
import type { LicenceReviewData } from '@/features/field/types';

// The licence images of one of the field staff member's own jobs, for review (migration 0162): the facts the office sees
// without the coverage, and a one-minute private link for each image waiting. The database checks the job is theirs and
// within the next 7 days, and logs each opening; the decisions go through fieldAct (licence_approve_all, licence_reject).
export async function fieldLicenceLoad(job: string): Promise<ActionResult<LicenceReviewData>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (!roles.field) throw new Error('Only field staff may do this.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const d = await door<LicenceReviewData>(user.id, 'field_read', 'licence_review', { job }, aal);
    const s = await storage();
    const uploads = await Promise.all(d.uploads.map(async (u) => ({
      ...u, bucket: undefined, path: undefined,
      url: u.status === 'submitted' && u.bucket && u.path ? await s.signedDownloadUrl(u.bucket as Bucket, u.path, 60).catch(() => null) : null
    })));
    return { ok: true, data: { ...d, uploads } };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
