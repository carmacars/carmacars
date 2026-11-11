'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { decryptField, encryptField, PAYOUT_KEY_VERSION } from '@/server/crypto';
import { sinDigits, validSin } from '@/features/field-portal/model';
import { imageSniff } from '@/lib/file-sniff';

// The field portal's steps with a file (release 35, part X; migrations 0930 and 0931): a clean check, money spent, a receipt added
// later, a service record, a prep item, photos of a car. The file goes to the private documents bucket first, under field/ (the
// database refuses any other path); then the door runs the step and checks the person, the car and the rule. The pay details:
// the SIN is encrypted here before it leaves the server (as the payout account numbers, 0730); only Finance and Admin open it,
// and the database logs each view before handing the sealed value back.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const MAX = 15_000_000;
const FILE_ACTIONS = { clean_check: 'photo', spend_add: 'receipt', spend_receipt: 'receipt', service_add: 'invoice', prep_item: 'document', car_photo: 'photo' } as const;
export type FieldFileAction = keyof typeof FILE_ACTIONS;

async function me(kind: 'field' | 'any' = 'field') {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  if (kind === 'field' && !roles.field) throw new Error('Only field staff may do this.');
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
  return { user, roles, aal };
}

/** Store one upload (PDF, JPEG or PNG) in the private documents bucket; returns what the database records. */
async function store(file: File, prefix: string) {
  if (file.size > MAX) throw new Error('The file must be under 15 MB.');
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
  const { jpg, png } = imageSniff(bytes);
  if (!pdf && !jpg && !png) throw new Error('Use a photo (JPEG or PNG) or a PDF.');
  const [type, ext] = pdf ? ['application/pdf', 'pdf'] : jpg ? ['image/jpeg', 'jpg'] : ['image/png', 'png'];
  const key = `${prefix}/${crypto.randomUUID()}.${ext}`;
  const { storage } = await import('@/integrations/storage');
  await (await storage()).put('documents', key, bytes, type!);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return { storage_path: key, mime_type: type!, sha256: Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join(''), title: file.name.slice(0, 200) };
}

/** One step with an optional file: form fields action, p (JSON) and file. */
export async function fieldWork<T = Record<string, unknown>>(form: FormData): Promise<R<T>> {
  try {
    const action = String(form.get('action') ?? '') as FieldFileAction;
    if (!(action in FILE_ACTIONS)) return { ok: false, code: 'invalid', message: 'Unknown step.' };
    const { user, aal } = await me();
    let p: Record<string, unknown>;
    try { p = JSON.parse(String(form.get('p') ?? '{}')) as Record<string, unknown>; } catch { return { ok: false, code: 'invalid', message: 'Something went wrong with the form. Try again.' }; }
    const file = form.get('file');
    if (file instanceof File && file.size > 0) p[FILE_ACTIONS[action]] = await store(file, `field/${new Date().getUTCFullYear()}`);
    const data = await door<T>(user.id, 'field_do', action, p, aal);
    revalidatePath('/staff/field', 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** Find a booking to help a renter on the spot: its number, the renter's name or phone (each search is logged). */
export async function helpFind(q: string): Promise<R<Array<{ id: string; number: string; status: string; pickup_at: string; return_at: string; renter: string | null; vehicle: string; mine: boolean }>>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door(user.id, 'field_read', 'help_find', { q: q.slice(0, 100) }, aal) };
  } catch (e) { return fail(e); }
}

/** Fleet and Admin give or take off onboarding prep. */
export async function prepDo(action: 'field_prep_assign' | 'field_prep_cancel', p: Record<string, unknown>): Promise<R<{ id: string }>> {
  try {
    const { user, aal } = await me('any');
    const data = await door<{ id: string }>(user.id, 'ops_do', action, p, aal);
    for (const x of ['/admin/field-jobs', '/staff/fleet', '/admin/owners', '/staff/owners']) revalidatePath(x, 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export interface PayIdentity { legal_name: string | null; email: string | null; phone: string | null; sin: string | null; cheque: boolean; complete: boolean; missing: string[] }
/** The pay details step: legal name, email, phone, SIN (encrypted here) and the void cheque (a private file under staff-pay/<user>/). */
export async function payIdentitySave(form: FormData): Promise<R<PayIdentity>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (!roles.field && !roles.va) throw new Error('Only staff may do this.');
    const aal = await sessionAal();
    if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const s = (k: string) => String(form.get(k) ?? '').trim();
    const p: Record<string, unknown> = { legal_name: s('legal_name') || null, email: s('email') || null, phone: s('phone') || null };
    const sin = sinDigits(s('sin'));
    if (sin) {
      if (!validSin(sin)) return { ok: false, code: 'invalid', message: 'Check the SIN: 9 digits, as on your SIN letter.', fieldErrors: { sin: 'Check the SIN.' } };
      Object.assign(p, { sin_enc: await encryptField(sin), sin_last3: sin.slice(-3), key_version: PAYOUT_KEY_VERSION });
    }
    const file = form.get('cheque');
    if (file instanceof File && file.size > 0) p.cheque = await store(file, `staff-pay/${user.id}`);
    const data = await door<PayIdentity>(user.id, roles.field ? 'field_do' : 'va_do', 'my_pay_identity_save', p, aal);
    revalidatePath('/staff/field', 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** Finance and Admin open a staff member's SIN or void cheque, with the reason (logged by the database first). */
export async function payIdentityReveal(p: { user: string; what: 'sin' | 'cheque'; reason: string }): Promise<R<{ value: string }>> {
  try {
    const { user, aal } = await me('any');
    const r = await door<{ sin_enc?: string; path?: string }>(user.id, 'ops_do', 'pay_identity_reveal', { user: p.user, what: p.what, reason: p.reason }, aal);
    if (p.what === 'sin') {
      const d = await decryptField(String(r.sin_enc ?? ''));
      return { ok: true, data: { value: `${d.slice(0, 3)}-${d.slice(3, 6)}-${d.slice(6)}` } };
    }
    const { storage } = await import('@/integrations/storage');
    return { ok: true, data: { value: await (await storage()).signedDownloadUrl('documents', String(r.path ?? ''), 300, 'void-cheque') } };
  } catch (e) { return fail(e); }
}

/** Finance and Admin: approve or refuse field spending, and mark it paid back. */
export async function spendDo(action: 'field_spend_decide' | 'field_spend_paid_back', p: { id: string; approve?: boolean; note?: string }): Promise<R<{ status: string }>> {
  try {
    const { user, aal } = await me('any');
    const data = await door<{ status: string }>(user.id, 'ops_do', action, p, aal);
    for (const x of ['/admin/money/field-pay', '/staff/field-spending']) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
