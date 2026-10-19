'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';
import { renderGuide } from '@/features/guides/markdown';
import { GUIDE_PATH, isGuidePortal } from '@/server/guides';

// The guides of migration 0044: the reader's banner, and Admin > Settings > Guides (save a draft, order, publish,
// images, the stored PDF). Every Admin action goes through the staff door; the database checks the Admin again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const refresh = (portal: string) => {
  revalidatePath('/admin/settings/guides');
  revalidatePath(`/admin/settings/guides/${portal}`);
  if (isGuidePortal(portal)) revalidatePath(GUIDE_PATH[portal]);
};

/** The reader dismissed the first-visit banner. */
export async function dismissGuideBanner(portal: string): Promise<R<null>> {
  try {
    const { user } = await me();
    if (!isGuidePortal(portal)) return { ok: false, code: 'invalid', message: 'Unknown guide.' };
    await rpc('guide_dismiss', { p_by: user.id, p_portal: portal }, { role: 'service_role' });
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export interface SectionInput { id?: string; portal: string; kind?: 'start' | 'chapter' | 'reference'; title: string; blurb: string; body_md: string; is_hidden: boolean; after?: string }
export async function saveGuideSection(s: SectionInput): Promise<R<{ id: string; draft_version: number }>> {
  try {
    const { user, aal } = await me();
    if (!s.title?.trim()) return { ok: false, code: 'invalid', message: 'Give the section a title.', fieldErrors: { title: 'Give the section a title.' } };
    if ((s.body_md ?? '').length > 200_000) return { ok: false, code: 'invalid', message: 'The text is too long for one section: split it in two.' };
    const r = await door<{ id: string; draft_version: number }>(user.id, 'ops_do', 'guide_section_save', {
      id: s.id || null, portal: s.portal, kind: s.kind ?? 'chapter', title: s.title.trim(), blurb: s.blurb?.trim() ?? '', body_md: s.body_md ?? '', is_hidden: !!s.is_hidden, after: s.after || null }, aal);
    refresh(s.portal);
    return { ok: true, data: { id: r.id, draft_version: r.draft_version } };
  } catch (e) { return fail(e); }
}

export async function moveGuideSection(portal: string, id: string, dir: 'up' | 'down'): Promise<R<null>> {
  try { const { user, aal } = await me(); await door(user.id, 'ops_do', 'guide_section_move', { id, dir }, aal); refresh(portal); return { ok: true, data: null }; } catch (e) { return fail(e); }
}

export async function deleteGuideSection(portal: string, id: string): Promise<R<null>> {
  try { const { user, aal } = await me(); await door(user.id, 'ops_do', 'guide_section_delete', { id }, aal); refresh(portal); return { ok: true, data: null }; } catch (e) { return fail(e); }
}

/** An earlier version's text, to read or restore. */
export async function guideVersion(section: string, version: number, published: boolean): Promise<R<{ title: string; blurb: string | null; body_md: string }>> {
  try { const { user, aal } = await me(); return { ok: true, data: await door(user.id, 'ops_read', 'guide_section_version', { section, version, published }, aal) }; } catch (e) { return fail(e); }
}

/** Publish: every section's draft is rendered here, once, and stored with the guide; the portals read that HTML. */
export async function publishGuide(portal: string): Promise<R<{ version: number; sections_changed: number }>> {
  try {
    const { user, aal } = await me();
    const g = await door<{ sections: Array<{ id: string; slug: string; kind: string; title: string; body_md: string; is_hidden: boolean }> }>(user.id, 'ops_read', 'guide_admin', { portal }, aal);
    const visible = g.sections.filter((s) => !s.is_hidden);
    const { html, warnings } = renderGuide(visible);
    if (warnings.length) return { ok: false, code: 'invalid', message: `Fix these first: ${warnings.slice(0, 5).join('; ')}` };
    const r = await door<{ version: number; sections_changed: number }>(user.id, 'ops_do', 'guide_publish', { portal, html }, aal);
    refresh(portal);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

const MAX_IMAGE = 4_000_000;
const MAX_PDF = 15_000_000;

/** A screenshot for a guide, into the public bucket. With replaces, every draft showing the old image shows the new one. */
export async function uploadGuideImage(form: FormData): Promise<R<{ url: string; markdown: string; sections_changed: number }>> {
  try {
    const { user, aal } = await me();
    const portal = String(form.get('portal') ?? '');
    if (!isGuidePortal(portal)) return { ok: false, code: 'invalid', message: 'Unknown guide.' };
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose an image.' };
    if (file.size > MAX_IMAGE) return { ok: false, code: 'invalid', message: 'The image must be under 4 MB (a JPEG of the screen is usually 100 to 300 KB).' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const jpg = bytes[0] === 0xff && bytes[1] === 0xd8, png = bytes[0] === 0x89 && bytes[1] === 0x50, webp = bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50;
    if (!jpg && !png && !webp) return { ok: false, code: 'invalid', message: 'Use a JPEG, PNG or WebP image.' };
    const [type, ext] = jpg ? ['image/jpeg', 'jpg'] : png ? ['image/png', 'png'] : ['image/webp', 'webp'];
    const sha = await sha256Hex(bytes);
    const key = `guides/${portal}/${sha.slice(0, 24)}.${ext}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('vehicle-public', key, bytes, type!);
    const url = s.publicUrl(key);
    const width = Number(form.get('width') ?? 0) || null, height = Number(form.get('height') ?? 0) || null;
    const phone = String(form.get('frame') ?? '') === 'phone' || (width && height ? height > width * 1.3 : false);
    const alt = String(form.get('alt') ?? '').slice(0, 200);
    const replaces = String(form.get('replaces') ?? '').trim() || null;
    const r = await door<{ sections_changed: number }>(user.id, 'ops_do', 'guide_image_record', { portal, url, storage_key: key, alt, width, height, bytes: bytes.byteLength, replaces_url: replaces }, aal);
    refresh(portal);
    const title = [phone ? 'phone' : 'desktop', width && height ? `size: ${width} ${height}` : ''].filter(Boolean).join('; ');
    return { ok: true, data: { url, markdown: `![${alt.replace(/[[\]]/g, '')}](${url} "${title}")`, sections_changed: r.sections_changed } };
  } catch (e) { return fail(e); }
}

/** A PDF of the guide an Admin made (for example with "Print or save as PDF"), stored as the guide's PDF. */
export async function uploadGuidePdf(form: FormData): Promise<R<null>> {
  try {
    const { user, aal } = await me();
    const portal = String(form.get('portal') ?? '');
    if (!isGuidePortal(portal)) return { ok: false, code: 'invalid', message: 'Unknown guide.' };
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose the PDF.' };
    if (file.size > MAX_PDF) return { ok: false, code: 'invalid', message: 'The PDF must be under 15 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) return { ok: false, code: 'invalid', message: 'That file is not a PDF.' };
    const sha = await sha256Hex(bytes);
    const key = `guides/${portal}/uploaded-${new Date().toISOString().slice(0, 10)}-${sha.slice(0, 12)}.pdf`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, bytes, 'application/pdf');
    const version = Number(form.get('version') ?? 0) || null;
    await door(user.id, 'ops_do', 'guide_pdf_record', { portal, bucket: 'documents', path: key, sha256: sha, bytes: bytes.byteLength, source: 'uploaded', guide_version: version }, aal);
    refresh(portal);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- the guides update themselves (0055, 0059): nothing to review
/** Undo a section's automatic change (migration 0055): the text it replaced comes back, published at once. */
export async function revertGuideAuto(portal: string, sectionId: string): Promise<R<{ version: number }>> {
  try {
    const { user, aal } = await me();
    if (!isGuidePortal(portal)) return { ok: false, code: 'invalid', message: 'Unknown guide.' };
    const r = await door<{ version: number }>(user.id, 'ops_do', 'guide_auto_revert', { id: sectionId }, aal);
    refresh(portal);
    return { ok: true, data: { version: r.version } };
  } catch (e) { return fail(e); }
}
