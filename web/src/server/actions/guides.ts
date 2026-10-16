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

// ---------------------------------------------------------------- guide upkeep: sections to review (migration 0049)
const REVIEW_SYSTEM = 'You keep a software user guide up to date. You get one chapter of the guide in Markdown and a new screenshot of the screen it describes. Return the chapter with only the changes the screenshot shows are needed: button and label names exactly as on the screen, steps in the order of the screen. Keep everything else word for word, including every image line, its title and its pins, the headings, the tips and the tables. Plain friendly language, short sentences, no em dashes, and the brand written CarmaCars. Answer in JSON.';
const REVIEW_SCHEMA = { type: 'object', properties: { body_md: { type: 'string' }, summary: { type: 'string' } }, required: ['body_md', 'summary'] };

/** Ask Workers AI for a suggested text of a section whose screenshot changed; kept beside the draft for the Admin. */
export async function suggestGuideText(portal: string, sectionId: string): Promise<R<{ summary: string }>> {
  try {
    const { user, aal } = await me();
    if (!isGuidePortal(portal)) return { ok: false, code: 'invalid', message: 'Unknown guide.' };
    const g = await door<{ sections: Array<{ id: string; title: string; body_md: string; review_images?: Array<{ new_url: string }> }> }>(user.id, 'ops_read', 'guide_admin', { portal }, aal);
    const s = g.sections.find((x) => x.id === sectionId);
    if (!s) return { ok: false, code: 'invalid', message: 'Section not found.' };
    const img = s.review_images?.at(-1)?.new_url;
    if (!img) return { ok: false, code: 'refused', message: 'No new screenshot to compare with.' };
    const gate = await door<{ allowed: boolean; reason?: string; model: string; fallback_model: string | null }>(user.id, 'ops_read', 'ai_vision_gate', { purpose: 'guide_review' }, aal);
    if (!gate.allowed) return { ok: false, code: 'refused', message: gate.reason ?? 'The vision model is not available.' };
    const { env } = await import('@/lib/env');
    const res = await fetch(/^https?:/.test(img) ? img : `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}${img}`);
    if (!res.ok) return { ok: false, code: 'refused', message: 'The new screenshot could not be read.' };
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.byteLength > 3_000_000) return { ok: false, code: 'refused', message: 'The screenshot is too large for the model.' };
    let bin = ''; for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    const { visionModel } = await import('@/integrations/vision');
    const t0 = Date.now();
    const r = await (await visionModel()).read({ purpose: 'guide_review', imageDataUrl: `data:${res.headers.get('content-type')?.startsWith('image/png') ? 'image/png' : 'image/jpeg'};base64,${btoa(bin)}`,
      system: REVIEW_SYSTEM, prompt: `The chapter "${s.title}":\n<<<GUIDE\n${s.body_md}\nGUIDE>>>\nReturn the whole chapter in body_md, and in summary one sentence on what you changed (or "No change needed").`,
      schema: REVIEW_SCHEMA, maxOutputTokens: 3000 }, [gate.model, gate.fallback_model ?? ''].filter(Boolean));
    await door(user.id, 'ops_do', 'ai_call_record', { purpose: 'guide_review', model: r.model ?? gate.model, ok: r.ok, error: r.ok ? null : `${r.reason}: ${r.message}`,
      neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0 }, aal).catch(() => undefined);
    if (!r.ok) return { ok: false, code: 'refused', message: `The model did not answer: ${r.message}` };
    const out = r.data as { body_md?: string; summary?: string };
    if (!out.body_md || out.body_md.length < 10) return { ok: false, code: 'refused', message: 'The model returned no text.' };
    const body = out.body_md.replace(/ ?[—–] ?/g, ', ');
    await door(user.id, 'ops_do', 'guide_suggestion_record', { id: s.id, body_md: body, model: r.model }, aal);
    refresh(portal);
    return { ok: true, data: { summary: out.summary ?? '' } };
  } catch (e) { return fail(e); }
}

/** The Admin's answer on a section to review: use the suggestion as the draft, dismiss it, or mark the section reviewed. */
export async function resolveGuideReview(portal: string, sectionId: string, action: 'apply_suggestion' | 'dismiss_suggestion' | 'reviewed'): Promise<R<null>> {
  try {
    const { user, aal } = await me();
    if (!isGuidePortal(portal)) return { ok: false, code: 'invalid', message: 'Unknown guide.' };
    await door(user.id, 'ops_do', 'guide_review_resolve', { id: sectionId, action }, aal);
    refresh(portal);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
