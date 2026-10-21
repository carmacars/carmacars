'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage, type Bucket } from '@/integrations/storage';
import type { DocReview } from '@/features/admin/todo/types';

// The guided actions (migration 0077): the pop-ups of Admin > Today and of the records. The database checks the person
// (an Admin, or the assistant function the action belongs to) and the rule; its refusal is shown as written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

// what each action changes on the public site
const PUBLIC = new Set(['todo_publish']);

export type GuidedAction = 'insurer_confirm' | 'insurer_confirm_bulk' | 'todo_publish' | 'doc_review_upload' | 'doc_review_coverage' | 'doc_review_plan' | 'form_verify';

/** Runs one guided action through the door; refreshes the Admin's To do and the given pages. */
export async function guidedAct<T = Record<string, unknown>>(action: GuidedAction, p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    const data = await door<T>(user.id, 'ops_do', action, p, aal);
    for (const x of ['/admin', ...refresh]) revalidatePath(x);
    if (PUBLIC.has(action)) { revalidatePath('/', 'layout'); revalidatePath('/cars/[slug]', 'page'); }
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** The renter documents of one booking, for review: the facts, and a one-minute private link for each page waiting. */
export async function docReviewLoad(booking: string): Promise<R<DocReview>> {
  try {
    const { user, aal } = await me();
    const d = await door<DocReview | null>(user.id, 'ops_read', 'doc_review', { booking }, aal);
    if (!d) throw new Error('Booking not found.');
    const s = await storage();
    const sign = async (bucket?: string | null, path?: string | null) => (bucket && path ? s.signedDownloadUrl(bucket as Bucket, path, 60).catch(() => null) : null);
    const uploads = await Promise.all(d.uploads.map(async (u) => ({ ...u, url: u.status === 'submitted' ? await sign(u.bucket, u.path) : null, bucket: undefined, path: undefined })));
    const proof = d.coverage?.proof ?? null;
    const pages = proof ? await Promise.all(proof.pages.map(async (pg) => ({ ...pg, url: await sign(pg.bucket, pg.path), bucket: undefined, path: undefined }))) : [];
    return { ok: true, data: { ...d, uploads, coverage: d.coverage ? { ...d.coverage, proof: proof ? { ...proof, pages } : null } : null } };
  } catch (e) { return fail(e); }
}
