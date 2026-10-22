'use server';
import { cookies } from 'next/headers';
import { env } from '@/lib/env';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import { verifyTurnstile } from '@/integrations/turnstile';
import { decodeVin } from '@/integrations/vin';
import type { ActionResult } from '@/features/forms/schemas';
import type { DecodedCar } from '@/features/vin/vin';
import { cleanVin, DRAFT_COOKIE, ownerErrors, planErrors, vehicleErrors, vehiclePayload, type ApplyState } from '@/features/owner/apply-schema';
import { currentUser } from '@/server/portal/data';
import { requestMeta } from '@/server/request';
import { passwordLinkTarget, rememberEmail } from '@/server/auth-links';

// The owner application wizard (04-owner.md section 3; 08-forms.md section 3). Every step autosaves
// to form_drafts: by account when signed in, otherwise by a device token kept in an httpOnly cookie.
// "Email me a link" sends a one-time link that opens the draft on another device. Submitting creates
// the owner account when needed and calls app.submit_owner_application (one owner, many vehicles).
const SR = { role: 'service_role' as const };
const FORM = 'owner_application';
type R<T = null> = ActionResult<T>;
const fail = (message: string, code = 'refused') => ({ ok: false as const, code, message });
const dbMessage = (e: unknown, fallback = 'Something went wrong. Please try again or call us.') => (e instanceof DbError ? e.message : fallback);

async function draftKey() {
  const user = await currentUser();
  const token = (await cookies()).get(DRAFT_COOKIE)?.value ?? null;
  return { user, token };
}

export async function saveApplyDraft(state: ApplyState): Promise<R<{ savedAt: string }>> {
  try {
    const { user, token } = await draftKey();
    const data = JSON.parse(JSON.stringify(state)) as Record<string, unknown>;
    let r: { draft_id: string; token: string | null; saved_at: string };
    try {
      r = (await rpc('save_form_draft', { p_form_code: FORM, p_data: data as never, p_step: String(state.step), p_user: user?.id, p_token: user ? undefined : token ?? undefined, p_device_label: (await requestMeta()).userAgent.slice(0, 60) }, SR)) as unknown as typeof r;
    } catch (e) {
      // the device token no longer opens a draft (submitted or expired): start a new one
      if (!user && token && e instanceof DbError && e.code === 'P0002') r = (await rpc('save_form_draft', { p_form_code: FORM, p_data: data as never, p_step: String(state.step) }, SR)) as unknown as typeof r;
      else throw e;
    }
    if (r.token) (await cookies()).set(DRAFT_COOKIE, r.token, { httpOnly: true, sameSite: 'lax', path: '/', secure: env().APP_ENV !== 'local', maxAge: 30 * 86400 });
    return { ok: true, data: { savedAt: r.saved_at } };
  } catch (e) { return fail(dbMessage(e, 'Not saved. Check your connection.')); }
}

export async function emailResumeLink(email: string): Promise<R> {
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email ?? '')) return { ok: false, code: 'invalid', message: 'Enter your email address.', fieldErrors: { resume_email: 'Enter your email address.' } };
  try {
    const { user, token } = await draftKey();
    const d = (await rpc('load_form_draft', { p_form_code: FORM, p_user: user?.id, p_token: user ? undefined : token ?? undefined }, SR)) as unknown as { draft_id: string } | null;
    if (!d) return fail('Nothing is saved yet. Fill in a step first.');
    const link = (await rpc('server_draft_resume_link', { p_draft: d.draft_id, p_email: email.trim(), p_user: user?.id, p_token: user ? undefined : token ?? undefined }, SR)) as unknown as string;
    const url = `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/list-your-car/apply/resume?t=${encodeURIComponent(link)}`;
    await rpc('server_send_link_email', { p_email: email.trim(), p_name: '', p_url: url, p_expiry: '24 hours', p_key: `owner-resume:${d.draft_id}:${Date.now()}` }, SR);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export interface VinResult {
  vin: string; valid: boolean; taken: boolean;
  /** the decode in the listing's words (0082): year, make, model, trim, body, seats, doors, fuel, drive, gearbox, engine */
  decode: (DecodedCar & { body_class?: string | null }) | null;
  /** false when the check digit does not add up (the VIN may be mistyped; it can still be used) */
  check_ok: boolean;
}

/** The owner's VIN, looked up at the 17th character: the decode on file, or the decoder now (stored once per VIN). */
export async function lookupVin(raw: string): Promise<R<VinResult>> {
  const vin = cleanVin(raw ?? '');
  try {
    const r = (await rpc('server_vin_lookup', { p_vin: vin }, SR)) as unknown as { valid: boolean; taken: boolean; decode: unknown };
    if (!r.valid) return { ok: false, code: 'invalid', message: 'Check the VIN: 17 letters and numbers, no I, O or Q.', fieldErrors: { vin: 'Check the VIN: 17 letters and numbers, no I, O or Q.' } };
    if (r.taken) return { ok: false, code: 'taken', message: 'This vehicle is already with CarmaCars. If it is yours, contact us.', fieldErrors: { vin: 'This vehicle is already with CarmaCars. If it is yours, contact us.' } };
    let f = (await rpc('server_vin_facts', { p_vin: vin }, SR)) as unknown as { decode: VinResult['decode']; check_ok: boolean; decode_failed_at: string | null };
    if (!f.decode && !(f.decode_failed_at && Date.now() - new Date(f.decode_failed_at).getTime() < 3_600_000)) {
      const d = await decodeVin(vin);
      await rpc('server_record_vin_decode', { p_vin: vin, p_provider: d.provider, p_output: d.result as never }, SR);
      f = (await rpc('server_vin_facts', { p_vin: vin }, SR)) as unknown as typeof f;
    }
    return { ok: true, data: { vin, valid: true, taken: false, decode: f.decode, check_ok: f.check_ok } };
  } catch (e) { return fail(dbMessage(e)); }
}

export interface MethodOption { situation: string; method: string; label: string; recommended: boolean; estimate_cents: number; estimate_with_lien_cents: number | null; plus_tax: boolean; typical_items: Array<{ item?: string; label?: string; cents?: number; amount_cents?: number }>; government_forms: string[]; sign_back_on_permit: boolean; carmacars_forms: string[] }

export async function methodOptions(heldBy: string, titleStatus: string, mode: string): Promise<R<MethodOption[]>> {
  if (!['individual', 'corporation'].includes(heldBy) || !['owned_outright', 'financed', 'leased'].includes(titleStatus) || !['managed', 'self_managed', 'turo_only'].includes(mode)) return { ok: true, data: [] };
  try {
    return { ok: true, data: (await rpc('server_onboarding_options', { p_held_by: heldBy, p_title_status: titleStatus, p_mode: mode }, SR)) as unknown as MethodOption[] };
  } catch (e) { return fail(dbMessage(e)); }
}

export interface SubmitResult { applicationNumber: string; vehicles: number; declined: number; checkEmail?: boolean; confirmEmail?: string }

export async function submitApplication(state: ApplyState, password: string, turnstileToken: string | null): Promise<R<SubmitResult>> {
  const o = state.owner;
  const fe: Record<string, string> = { ...ownerErrors(o) };
  if (!state.vehicles.length) return fail('Add at least one vehicle.');
  state.vehicles.forEach((v, i) => { for (const [k, m] of Object.entries({ ...vehicleErrors(v, o.owner_type), ...planErrors(v) })) fe[`v${i}.${k}`] = m; });
  let user = await currentUser();
  let onRecord = false;
  let confirmEmail: string | null = null;
  if (!user && (password ?? '').length < 10) fe.password = 'Choose a password of at least 10 characters.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Some answers need a look. The first one is highlighted.', fieldErrors: fe };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(turnstileToken, meta.ip))) return fail('We could not confirm you are not a bot. Reload the page and try again.', 'turnstile');
  const name = [o.first_name, o.middle_name, o.last_name].map((x) => x.trim()).filter(Boolean).join(' ');
  const phoneDigits = o.phone.replace(/[^\d+]/g, '');
  const phone = phoneDigits.startsWith('+') ? phoneDigits : phoneDigits.length === 10 ? `+1${phoneDigits}` : `+${phoneDigits}`;
  try {
    const onFile = user ? null : (await rpc('server_user_by_email', { p_email: o.email.trim().toLowerCase() }, SR).catch(() => null)) as unknown as string | null;
    if (!user && onFile) {
      // The address is on file (an earlier booking request, or a record staff made) with no sign-in yet: a sign-in for
      // that record and one email, the link to choose the password (opening it proves the address). Asked before any
      // sign-up, so Supabase never also sends a confirmation for a sign-in that would be removed again.
      const a = await auth();
      const made = a.createForRecord ? await a.createForRecord(onFile, o.email.trim().toLowerCase(), name, passwordLinkTarget()) : null;
      if (made && !made.ok && made.code === 'exists') return { ok: false, code: 'account', message: 'An account with this email already exists. Sign in first, then apply.', fieldErrors: { password: 'An account with this email already exists. Sign in first, then apply.' } };
      if (!made?.ok) return fail('We already have a booking request with this email. Call us and we will finish your application.');
      user = { id: onFile, email: o.email.trim().toLowerCase() };
      onRecord = true;
    }
    if (!user) {
      const a = await auth();
      const r = await a.signUp(o.email.trim().toLowerCase(), password, { full_name: name });
      if (!r.ok) return { ok: false, code: 'account', message: r.message, fieldErrors: { password: r.message } };
      user = r.user;
      // Supabase emails the confirmation link (its only email at sign-up); the account signs in once it is opened
      if (r.needsConfirmation) confirmEmail = r.user.email;
      const reg = (await rpc('register_account', { p_user: user.id, p_email: user.email, p_full_name: name, p_phone: phone }, SR)) as unknown as { ok?: boolean; error?: string };
      if (reg && reg.ok === false && reg.error === 'email_on_record' && a.createForRecord && a.deleteAccount) {
        // The address is on file from an earlier booking request, without a sign-in (migration 0040): the sign-in just
        // made is removed, the application goes on that record, and the record gets a sign-in with a link to the address
        // to choose the password. Opening it proves the address; the earlier requests and the owner portal are then theirs.
        await a.signOut().catch(() => undefined);
        await a.deleteAccount(user.id);
        const id = (await rpc('server_user_by_email', { p_email: o.email.trim().toLowerCase() }, SR)) as unknown as string | null;
        const made = id ? await a.createForRecord(id, o.email.trim().toLowerCase(), name, passwordLinkTarget()) : null;
        if (!id || !made?.ok) return fail('We already have a booking request with this email. Call us and we will finish your application.');
        user = { id, email: o.email.trim().toLowerCase() };
        onRecord = true;
        confirmEmail = null;
      } else if (reg && reg.ok === false) return fail('We could not open your account. Call us and we will finish your application.');
    }
    const token = (await cookies()).get(DRAFT_COOKIE)?.value;
    const draft = (await rpc('load_form_draft', { p_form_code: FORM, p_user: user.id }, SR).catch(() => null)) as unknown as { draft_id: string } | null
      ?? (token ? (await rpc('load_form_draft', { p_form_code: FORM, p_token: token }, SR).catch(() => null)) as unknown as { draft_id: string } | null : null);
    const res = (await rpc('server_submit_owner_application', { p: {
      source: 'web', draft_id: draft?.draft_id ?? null,
      owner: {
        owner_type: o.owner_type, legal_name: name, first_name: o.first_name.trim(), middle_name: o.middle_name.trim() || null, last_name: o.last_name.trim(),
        corporation_name: o.owner_type === 'corporation' ? o.corporation_name.trim() : null, corporation_number: o.owner_type === 'corporation' ? o.corporation_number.trim() : null,
        signing_officer_name: o.owner_type === 'corporation' ? name : null, signing_officer_title: o.owner_type === 'corporation' ? o.signing_officer_title.trim() : null,
        address_line1: o.address_line1.trim(), address_line2: o.address_line2.trim() || null, city: o.city.trim(), province: o.province, postal_code: o.postal_code.trim(), country: 'CA',
        email: o.email.trim().toLowerCase(), phone, hst_number: o.hst_number.replace(/\s/g, '') || null,
        licence_number: o.owner_type === 'individual' ? o.licence_number.replace(/\s/g, '').toUpperCase() : null,
        date_of_birth: o.owner_type === 'individual' ? o.date_of_birth : null, referred_by: o.referred_by.trim() || null
      },
      vehicles: state.vehicles.map(vehiclePayload)
    }, p_by: user.id }, SR)) as unknown as { application_number: string; vehicles: Array<{ declined: boolean }> };
    (await cookies()).delete(DRAFT_COOKIE);
    if (confirmEmail || onRecord) await rememberEmail(user.email);
    { const { afterCarAdded } = await import('@/server/car-added'); afterCarAdded(); }   // each car's copy at once (0082)
    return { ok: true, data: { applicationNumber: res.application_number, vehicles: res.vehicles.length, declined: res.vehicles.filter((v) => v.declined).length, ...(onRecord ? { checkEmail: true } : {}), ...(confirmEmail ? { confirmEmail } : {}) } };
  } catch (e) { return fail(dbMessage(e)); }
}
