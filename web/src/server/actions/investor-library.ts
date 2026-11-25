'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { assertAdmin } from '@/server/admin/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { isPdf, LIBRARY_MAX_BYTES, validLink } from '@/features/investor/library';

// Admin > Investors > Documents (r50, migration 4300): add a business document or replace one with a new version. A PDF is
// checked (its first bytes, under 50 MB), stored privately under investor-library/<item>/<file>.pdf in the documents
// bucket, then registered by the database (app.investor_library_save), which checks the Admin again, keeps every earlier
// version and tells every active investor. A deck may be an https link instead of a file.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : String(e) });
const UUID = /^[0-9a-f-]{36}$/;

export async function investorLibrarySave(form: FormData): Promise<R<{ item: string; version: number; told: number }>> {
  try {
    const user = await assertAdmin();
    const aal = await sessionAal();
    const item = String(form.get('item') ?? '');
    const p: Record<string, unknown> = {};
    if (item) { if (!UUID.test(item)) return fail('Unknown document.'); p.item = item; }
    const title = String(form.get('title') ?? '').trim().slice(0, 120);
    const kind = String(form.get('kind') ?? '').trim();
    const kindLabel = String(form.get('kind_label') ?? '').trim().slice(0, 60);
    const note = String(form.get('note') ?? '').trim().slice(0, 500);
    if (title) p.title = title;
    if (!item) {
      if (title.length < 3) return fail('Give the document a title.');
      if (kind === '_new') { if (kindLabel.length < 2) return fail('Name the new section.'); p.kind_label = kindLabel; } else p.kind = kind;
    }
    if (note) p.note = note;
    const link = String(form.get('link_url') ?? '').trim();
    const file = form.get('file');
    if (file instanceof Blob && file.size > 0) {
      if (file.size > LIBRARY_MAX_BYTES) return fail('The PDF must be under 50 MB.');
      const bytes = new Uint8Array(await file.arrayBuffer());
      if (!isPdf(bytes)) return fail('Upload a PDF, or give a link to the deck.');
      const folder = item || crypto.randomUUID();
      const key = `investor-library/${folder}/${crypto.randomUUID()}.pdf`;
      const s = await storage();
      await s.put('documents', key, bytes, 'application/pdf');
      try {
        const r = await door<{ item: string; version: number; told: number }>(user.id, 'admin_do', 'investor_library_save', { ...p, file_kind: 'pdf', path: key, size_bytes: bytes.length, sha256: await sha256Hex(bytes) }, aal);
        done();
        return { ok: true, data: r };
      } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
    }
    if (!link) return fail('Choose a PDF or give a link to the deck.');
    if (!validLink(link)) return fail('The link must start with https://');
    const r = await door<{ item: string; version: number; told: number }>(user.id, 'admin_do', 'investor_library_save', { ...p, file_kind: 'link', link_url: link }, aal);
    done();
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

function done() {
  revalidatePath('/admin/investors/documents');
  revalidatePath('/investor/documents');
}
