'use server';
import { revalidatePath } from 'next/cache';
import { randomUUID } from 'node:crypto';
import { env } from '@/lib/env';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { auth } from '@/lib/auth';
import type { ActionResult } from '@/features/forms/schemas';
import { assertAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';

// The admin portal's actions (migration 0030). One door for every action: the Admin is checked here
// (and two-step sign-in when required), then the database checks the Admin again and runs the function
// of the migration that owns the rule. The database's refusal is shown to the Admin as it is written.
const SR = { role: 'service_role' as const };
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

// what the public site shows, by action: the pages to rebuild after the change
const PUBLIC: Record<string, string[]> = {
  rate_card: ['/cars/[slug]', '/cars', '/', '/rent/[hub]'],
  bulk_rate_apply: ['/cars/[slug]', '/cars', '/', '/rent/[hub]'],
  vehicle_deposit: ['/cars/[slug]'],
  fee_override: ['/cars/[slug]'], fee_override_end: ['/cars/[slug]'],
  listing_review: ['/cars/[slug]', '/cars', '/', '/rent/[hub]', '/sitemap.xml'],
  listing_publish: ['/cars/[slug]', '/cars', '/', '/rent/[hub]', '/sitemap.xml'],
  listing_unlist: ['/cars/[slug]', '/cars', '/', '/rent/[hub]', '/sitemap.xml'],
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
    const data = (await rpc('admin_do', { p_admin: admin.id, p_action: action, p: p as unknown as Json }, SR)) as unknown as T;
    rebuild([...(PUBLIC[action] ?? []), ...refresh]);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** A settings row: add (no key) or change (key). Program settings are a new dated row. */
export async function adminSaveRow<T = Record<string, unknown>>(table: string, values: Record<string, unknown>, key?: string | null, extra: Record<string, unknown> = {}): Promise<R<T>> {
  try {
    const admin = await assertAdmin();
    const data = (await rpc('admin_save', { p_admin: admin.id, p_table: table, p: { key: key ?? null, values, ...extra } as unknown as Json }, SR)) as unknown as T;
    // settings and content reach every public page
    if (['site_settings', 'site_content_blocks', 'program_settings', 'fee_defaults', 'deposit_tiers', 'km_allowance_choices', 'vehicle_classes', 'airports', 'coverage_prices', 'fee_types'].includes(table)) revalidatePath('/', 'layout');
    revalidatePath('/admin/settings', 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** A read from a client component (previews: re-pricing, calendar moves, bulk rates). */
export async function adminPreview<T = Record<string, unknown>>(what: 'booking_preview' | 'calendar_preview' | 'bulk_rate_preview' | 'cancellation_preview' | 'quote_vehicles' | 'calendar' | 'toll_profile', p: Record<string, unknown>): Promise<R<T>> {
  try {
    const admin = await assertAdmin();
    return { ok: true, data: await adminRead<T>(admin.id, what, p) };
  } catch (e) { return fail(e); }
}

/** Invite a staff member: the sign-in account first (an emailed link to choose a password), then the roles. */
export async function inviteStaff(i: { email: string; full_name: string; role: string; va_function?: string; field_function?: string }): Promise<R<{ user_id: string }>> {
  const email = (i.email ?? '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: { email: 'Enter an email address.' } };
  if ((i.full_name ?? '').trim().length < 2) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: { full_name: 'Enter the name.' } };
  if (!['admin', 'va', 'field'].includes(i.role)) return { ok: false, code: 'invalid', message: 'Choose the role.' };
  if (i.role === 'va' && !i.va_function) return { ok: false, code: 'invalid', message: 'Choose the assistant\'s function.', fieldErrors: { va_function: 'Choose one.' } };
  if (i.role === 'field' && !i.field_function) return { ok: false, code: 'invalid', message: 'Choose the field function.', fieldErrors: { field_function: 'Choose one.' } };
  try {
    const admin = await assertAdmin();
    const a = await auth();
    const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
    const invited = a.invite ? await a.invite(email, i.full_name.trim(), `${base}/update-password`) : { ok: false as const, message: 'Invitations are not available.' };
    if (!invited.ok) return { ok: false, code: 'refused', message: invited.message };
    await rpc('admin_do', { p_admin: admin.id, p_action: 'staff_add', p: { user_id: invited.user.id, email, full_name: i.full_name.trim(), role: i.role,
      va_function: i.va_function || null, field_function: i.field_function || null } as unknown as Json }, SR);
    revalidatePath('/admin/settings/staff');
    return { ok: true, data: { user_id: invited.user.id } };
  } catch (e) { return fail(e); }
}

/** The site logo (light or dark background): stored in the public bucket, then the setting points to it. */
export async function uploadLogo(form: FormData): Promise<R<{ key: string }>> {
  try {
    await assertAdmin();
    const file = form.get('file');
    const which = form.get('which') === 'dark' ? 'dark' : 'light';
    if (!(file instanceof File) || file.size === 0) return { ok: false, code: 'invalid', message: 'Choose an image file.' };
    if (file.size > 1_000_000) return { ok: false, code: 'invalid', message: 'The logo must be under 1 MB.' };
    const type = file.type;
    const ext = type === 'image/svg+xml' ? 'svg' : type === 'image/png' ? 'png' : type === 'image/webp' ? 'webp' : null;
    if (!ext) return { ok: false, code: 'invalid', message: 'Use an SVG, PNG or WebP image.' };
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (ext === 'png' && !(bytes[0] === 0x89 && bytes[1] === 0x50)) return { ok: false, code: 'invalid', message: 'That file is not a PNG image.' };
    const key = `site/logo-${which}-${randomUUID().slice(0, 8)}.${ext}`;
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
    const r = await adminSaveRow('site_settings', which === 'dark' ? { logo_dark_file_key: key } : { logo_light_file_key: key });
    if (!r.ok) return r;
    return { ok: true, data: { key } };
  } catch (e) { return fail(e); }
}

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
