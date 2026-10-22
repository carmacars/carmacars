'use server';
import { revalidatePath } from 'next/cache';
import { randomUUID } from 'node:crypto';
import { DbError } from '@/lib/db/repo';
import { door } from '@/server/door';
import { auth } from '@/lib/auth';
import type { ActionResult } from '@/features/forms/schemas';
import { assertAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';

// The admin portal's actions (migration 0030). One door for every action: the Admin is checked here
// (and two-step sign-in when required), then the database checks the Admin again and runs the function
// of the migration that owns the rule. The database's refusal is shown to the Admin as it is written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

// what the public site shows, by action: the pages to rebuild after the change
const PUBLIC: Record<string, string[]> = {
  // the vehicle pages (0097): the trims and the popular list change their pages and the sitemaps
  vehicle_pages_trims: ['/'], vehicle_pages_popular: ['/'],
  rate_card: ['/cars/[slug]', '/cars', '/', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]'],
  bulk_rate_apply: ['/cars/[slug]', '/cars', '/', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]'],
  vehicle_deposit: ['/cars/[slug]'],
  fee_override: ['/cars/[slug]'], fee_override_end: ['/cars/[slug]'],
  listing_review: ['/cars/[slug]', '/cars', '/', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]', '/sitemap.xml'],
  listing_publish: ['/cars/[slug]', '/cars', '/', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]', '/sitemap.xml'],
  listing_publish_now: ['/cars/[slug]', '/cars', '/', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]', '/sitemap.xml'],
  listing_unlist: ['/cars/[slug]', '/cars', '/', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]', '/sitemap.xml'],
  vehicle_sample: ['/cars/[slug]', '/cars/[slug]/[model]', '/cars/[slug]/[model]/[year]', '/cars/[slug]/[model]/[year]/[trim]', '/sitemap.xml'],
  review_publish: ['/cars/[slug]', '/'], review_hide: ['/cars/[slug]', '/'],
  block_create: ['/cars/[slug]'], block_remove: ['/cars/[slug]'], block_end: ['/cars/[slug]'], block_update: ['/cars/[slug]'],
  vehicle_status: ['/cars/[slug]', '/cars', '/']
};

function rebuild(paths: string[]) {
  for (const p of paths) {
    if (p.includes('[')) revalidatePath(p, 'page');
    else if (p === '/') revalidatePath('/', 'layout');
    else revalidatePath(p);
  }
}

/** Runs one admin action. `refresh` names admin pages to re-render. */
export async function adminAct<T = Record<string, unknown>>(action: string, p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const admin = await assertAdmin();
    // an owner statement is emailed with a 7-day link to its PDF: the PDF is rendered and stored first
    if (action === 'statement_issue' && typeof p.id === 'string') {
      const { generatedFile } = await import('@/server/files');
      if (!(await generatedFile('owner_statement', p.id, admin.id))) throw new Error('The statement PDF could not be made.');
    }
    const data = await door<T>(admin.id, 'admin_do', action, p);
    rebuild([...(PUBLIC[action] ?? []), ...refresh]);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** A settings row: add (no key) or change (key). Program settings are a new dated row. */
export async function adminSaveRow<T = Record<string, unknown>>(table: string, values: Record<string, unknown>, key?: string | null, extra: Record<string, unknown> = {}): Promise<R<T>> {
  try {
    const admin = await assertAdmin();
    const data = await door<T>(admin.id, 'admin_save', table, { key: key ?? null, values, ...extra });
    // settings and content reach every public page
    if (['site_settings', 'site_content_blocks', 'program_settings', 'fee_defaults', 'deposit_tiers', 'km_allowance_choices', 'vehicle_classes', 'airports', 'coverage_prices', 'fee_types'].includes(table)) revalidatePath('/', 'layout');
    revalidatePath('/admin/settings', 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** A read from a client component (previews: re-pricing, calendar moves, bulk rates). */
export async function adminPreview<T = Record<string, unknown>>(what: 'booking_preview' | 'calendar_preview' | 'bulk_rate_preview' | 'cancellation_preview' | 'quote_vehicles' | 'calendar' | 'toll_profile' | 'change_preview' | 'change_vehicles' | 'driver_links' | 'vehicle_similarity' | 'addons_for_car', p: Record<string, unknown>): Promise<R<T>> {
  try {
    const admin = await assertAdmin();
    return { ok: true, data: await adminRead<T>(admin.id, what, p) };
  } catch (e) { return fail(e); }
}

export interface InviteInput {
  email: string; full_name?: string; role: string; va_function?: string; cover_functions?: string[]; field_function?: string;
  owner_id?: string; investor_id?: string;
}

/** Invite a person into a role: admin, assistant (with the functions they cover), field, an owner on file or an
 *  investor on file. The sign-in account is made first and emailed a link to choose a password (Supabase's branded
 *  invitation, which lands on /update-password and then their portal); then the database gives it the role
 *  (app.admin_invite_account, 0036). Someone who already signs in just gets the role: no email. */
export async function inviteAccount(i: InviteInput): Promise<R<{ user_id: string; existed: boolean; email: string }>> {
  const email = (i.email ?? '').trim().toLowerCase();
  const fe: Record<string, string> = {};
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) fe.email = 'Enter an email address.';
  if (!['admin', 'va', 'field', 'owner', 'investor'].includes(i.role)) fe.role = 'Choose the role.';
  if (['admin', 'va', 'field'].includes(i.role) && (i.full_name ?? '').trim().length < 2) fe.full_name = 'Enter the name.';
  if (i.role === 'va' && !i.va_function) fe.va_function = 'Choose one.';
  if (i.role === 'field' && !i.field_function) fe.field_function = 'Choose one.';
  if (i.role === 'owner' && !i.owner_id) fe.owner_id = 'Choose the owner on file.';
  if (i.role === 'investor' && !i.investor_id) fe.investor_id = 'Choose the investor on file.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  try {
    const admin = await assertAdmin();
    const a = await auth();
    const { rpc } = await import('@/lib/db/repo');
    const { passwordLinkTarget } = await import('@/server/auth-links');
    const name = (i.full_name ?? '').trim();
    if (!a.invite || !a.createForRecord) return { ok: false, code: 'refused', message: 'Invitations are not available.' };
    let userId = (await rpc('server_user_by_email', { p_email: email }, { role: 'service_role' })) as unknown as string | null;
    let existed = false;
    if (userId) {
      // already on file (a renter, a booking request, an earlier invitation): a sign-in for that record, unless it has one
      const made = await a.createForRecord(userId, email, name, passwordLinkTarget());
      if (!made.ok && made.code === 'exists') existed = true;
      else if (!made.ok) return { ok: false, code: 'refused', message: made.message };
    } else {
      const invited = await a.invite(email, name, passwordLinkTarget());
      if (!invited.ok) return { ok: false, code: 'refused', message: invited.code === 'exists'
        ? 'This address has a sign-in that is not linked to a CarmaCars record. Ask them to use Forgot password, then invite them again.' : invited.message };
      userId = invited.user.id;
    }
    await rpc('admin_invite_account', { p_admin: admin.id, p: { user_id: userId, email, full_name: name || null, role: i.role, va_function: i.va_function || null,
      cover_functions: (i.cover_functions ?? []).filter(Boolean), field_function: i.field_function || null, owner_id: i.owner_id || null, investor_id: i.investor_id || null } }, { role: 'service_role' });
    revalidatePath('/admin/settings/staff'); revalidatePath('/admin/portals'); revalidatePath('/admin/owners'); revalidatePath('/admin/investors');
    return { ok: true, data: { user_id: userId, existed, email } };
  } catch (e) { return fail(e); }
}

/** Sends a person the link to choose a password (a new invitation link for someone who never chose one, or a reset
 *  for someone who forgot it). The same branded email as "Forgot password"; the link works for 24 hours. */
export async function sendPasswordLink(userId: string): Promise<R<{ email: string }>> {
  try {
    const admin = await assertAdmin();
    if (!/^[0-9a-f-]{36}$/i.test(userId ?? '')) return { ok: false, code: 'invalid', message: 'Choose a person.' };
    const { rpc } = await import('@/lib/db/repo');
    const { passwordLinkTarget } = await import('@/server/auth-links');
    const u = (await rpc('admin_account_link', { p_admin: admin.id, p_user: userId }, { role: 'service_role' })) as unknown as { email: string };
    await (await auth()).requestPasswordReset(u.email, passwordLinkTarget());
    return { ok: true, data: { email: u.email } };
  } catch (e) { return fail(e); }
}

/** The site logo (light or dark background), the favicon or the social sharing image: stored in the public
 *  bucket, then the setting points to it. */
export async function uploadLogo(form: FormData): Promise<R<{ key: string }>> {
  try {
    await assertAdmin();
    const file = form.get('file');
    const w = String(form.get('which'));
    const which = w === 'dark' || w === 'favicon' || w === 'og' ? w : 'light';
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose an image file.' };
    if (file.size > (which === 'og' ? 3_000_000 : 1_000_000)) return { ok: false, code: 'invalid', message: which === 'og' ? 'The sharing image must be under 3 MB.' : 'The image must be under 1 MB.' };
    const type = file.type;
    const ext = type === 'image/svg+xml' && which !== 'og' ? 'svg' : type === 'image/png' ? 'png' : type === 'image/webp' && which !== 'og' ? 'webp' : type === 'image/jpeg' && which === 'og' ? 'jpg' : null;
    if (!ext) return { ok: false, code: 'invalid', message: which === 'og' ? 'Use a PNG or JPEG image, 1200 by 630.' : 'Use an SVG, PNG or WebP image.' };
    if (ext === 'jpg' && !(bytes0(await file.slice(0, 2).arrayBuffer()))) return { ok: false, code: 'invalid', message: 'That file is not a JPEG image.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (ext === 'png' && !(bytes[0] === 0x89 && bytes[1] === 0x50)) return { ok: false, code: 'invalid', message: 'That file is not a PNG image.' };
    const key = `site/${which === 'favicon' || which === 'og' ? which : `logo-${which}`}-${randomUUID().slice(0, 8)}.${ext}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('vehicle-public', key, bytes, type);
    if (s.name === 'local') {
      // the local public bucket is served from public/_local (see README, "The local stack")
      const { mkdir, writeFile } = await import('node:fs/promises');
      const path = await import('node:path');
      const target = path.join(/* turbopackIgnore: true */ process.cwd(), 'public/_local/vehicle-public', key);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, bytes);
    }
    const col = { light: 'logo_light_file_key', dark: 'logo_dark_file_key', favicon: 'favicon_file_key', og: 'og_image_file_key' }[which];
    const r = await adminSaveRow('site_settings', { [col]: key });
    if (!r.ok) return r;
    return { ok: true, data: { key } };
  } catch (e) { return fail(e); }
}

const bytes0 = (b: ArrayBuffer) => { const u = new Uint8Array(b); return u[0] === 0xff && u[1] === 0xd8; };

/** A notice, receipt or estimate (PDF or image): stored in the private documents bucket and filed. */
export async function uploadAdminDocument(form: FormData): Promise<R<{ id: string }>> {
  try {
    await assertAdmin();
    const file = form.get('file');
    const kind = String(form.get('kind') ?? 'other');
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose a file.' };
    if (file.size > 15_000_000) return { ok: false, code: 'invalid', message: 'The file must be under 15 MB.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
    const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
    const png = bytes[0] === 0x89 && bytes[1] === 0x50;
    if (!pdf && !jpg && !png) return { ok: false, code: 'invalid', message: 'Use a PDF, JPEG or PNG file.' };
    const type = pdf ? 'application/pdf' : jpg ? 'image/jpeg' : 'image/png';
    const { createHash } = await import('node:crypto');
    const key = `admin/${kind}/${randomUUID()}.${pdf ? 'pdf' : jpg ? 'jpg' : 'png'}`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, bytes, type);
    return adminAct<{ id: string }>('document_register', { kind, title: String(form.get('title') ?? file.name).slice(0, 200), storage_path: key, mime_type: type, sha256: createHash('sha256').update(bytes).digest('hex') });
  } catch (e) { return fail(e); }
}
