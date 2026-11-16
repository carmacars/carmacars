'use server';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage, type Bucket } from '@/integrations/storage';
import type { DocViewResult } from '@/features/docs-view/types';

// r48 (3071): one reviewed renter document viewed again (a licence image, the selfie, a page of the proof of coverage), at
// any status. The database decides who may (the staff who review the booking's documents; never an owner) and writes the
// view to the audit log; the link is private and valid one minute. A purged document answers the day it was removed.
const CALLS = new Set(['ops_read', 'va_read', 'field_read'] as const);
type ViewCall = 'ops_read' | 'va_read' | 'field_read';

export async function docViewOpen(upload: string, call: ViewCall = 'ops_read'): Promise<ActionResult<DocViewResult>> {
  try {
    if (!/^[0-9a-f-]{36}$/i.test(upload) || !CALLS.has(call)) throw new Error('Document not found.');
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const d = await door<{ removed_on?: string | null; mime_type?: string | null; bucket?: string | null; path?: string | null }>(user.id, call, 'doc_view', { upload }, await sessionAal());
    if (d.removed_on) return { ok: true, data: { url: null, mime_type: null, removed_on: d.removed_on } };
    if (!d.bucket || !d.path) throw new Error('The file is not available.');
    const url = await (await storage()).signedDownloadUrl(d.bucket as Bucket, d.path, 60);
    return { ok: true, data: { url, mime_type: d.mime_type ?? null, removed_on: null } };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
