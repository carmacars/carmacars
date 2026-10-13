'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { payments, fakeOnly } from '@/integrations/payments';
import { storage, type Bucket } from '@/integrations/storage';
import { consents, CONSENT_VERSION, consentLine, SIGN_STATEMENT } from '@/features/agreement/model';
import { bookingPath } from '@/features/portal/status';
import type { MyBooking } from '@/features/portal/types';
import type { ActionResult } from '@/features/forms/schemas';
import { requestMeta } from '@/server/request';
import { readToken, sha256Hex, signToken } from '@/server/links';
import { findBooking, requireUser } from '@/server/portal/data';
import { openAgreement } from '@/server/portal/agreement';
import { bookingIntent, paymentFacts, reasonMessage, settleIntent, type SettleResult } from '@/server/portal/payment';
import { consentTexts } from '@/server/booking-data';

// Every renter action: a server action (POST with a same-origin check by Next.js), run for the
// signed-in user, re-checking that the booking is theirs (public.my_booking under row-level security)
// before the service role calls a wrapper that checks again in the database (p_by is the renter).
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
const fail = (message: string, code = 'refused'): { ok: false; code: string; message: string } => ({ ok: false, code, message });
const dbMessage = (e: unknown, fallback = 'Something went wrong. Please try again or call us.') => (e instanceof DbError ? e.message : fallback);

async function mine(number: string): Promise<{ userId: string; b: MyBooking }> {
  const user = await requireUser(bookingPath(number));
  const b = await findBooking(user, number);
  if (!b) throw new DbError('Booking not found', 'P0002');
  return { userId: user.id, b };
}
const refresh = (n: string) => { revalidatePath(bookingPath(n)); revalidatePath('/account'); };

// ---------------------------------------------------------------- offer
export async function approveOffer(number: string, version: number): Promise<R> {
  let target = '';
  try {
    const { userId, b } = await mine(number);
    if (b.status !== 'offered' || b.current_offer_version !== version) return fail('This offer was updated. Review the new version.', 'stale');
    await rpc('renter_approve_offer', { p_booking: b.id, p_version: version, p_by: userId }, SR);
    await openAgreement(b.id, userId);
    refresh(number);
    target = bookingPath(number, 'sign');
  } catch (e) {
    const m = dbMessage(e);
    return fail(/stale|version|expired|superseded|no longer/i.test(m) ? 'This offer was updated. Review the new version.' : m, 'stale');
  }
  redirect(target);
}

export async function requestOfferChange(number: string, note: string): Promise<R> {
  const n = (note ?? '').trim();
  if (n.length < 10 || n.length > 500) return { ok: false, code: 'invalid', message: 'Tell us what to change, in 10 to 500 characters.', fieldErrors: { note: 'Write 10 to 500 characters.' } };
  try {
    const { userId, b } = await mine(number);
    await rpc('renter_request_offer_change', { p_booking: b.id, p_by: userId, p_note: n }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

const DECLINE = ['I found another car', 'The price', 'My dates changed', 'Other'];
export async function declineOffer(number: string, reason: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    const why = DECLINE.includes(reason) ? reason : 'Other';
    await rpc('renter_withdraw_request', { p_booking: b.id, p_by: userId, p_note: `Declined by the renter: ${why}` }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function withdrawRequest(number: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    await rpc('renter_withdraw_request', { p_booking: b.id, p_by: userId, p_note: 'Withdrawn by the renter' }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function replyInfo(number: string, requestId: string, reply: string): Promise<R> {
  const t = (reply ?? '').trim();
  if (t.length < 2 || t.length > 2000) return { ok: false, code: 'invalid', message: 'Write your answer (up to 2,000 characters).', fieldErrors: { reply: 'Write your answer.' } };
  try {
    const { userId, b } = await mine(number);
    if (!b.info_requests.some((q) => q.id === requestId && q.status === 'open')) return fail('This question is already answered.');
    await rpc('renter_reply_booking_info', { p_request: requestId, p_by: userId, p_reply: t }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- details and signing
export interface DetailsInput { address_line1: string; address_line2?: string; city: string; province: string; postal_code: string; country: string; licence_number: string; licence_class: string; licence_issuer: string; licence_expiry: string }

export async function saveDetails(number: string, d: DetailsInput): Promise<R> {
  const fe: Record<string, string> = {};
  for (const k of ['address_line1', 'city', 'province', 'postal_code', 'country', 'licence_number', 'licence_issuer', 'licence_expiry'] as const) if (!String(d[k] ?? '').trim()) fe[k] = 'Required.';
  if (d.licence_issuer === 'ON' && d.licence_number && !/^[A-Z]\d{4}-?\d{5}-?\d{5}$/i.test(d.licence_number.replace(/\s/g, ''))) fe.licence_number = 'An Ontario licence number looks like A1234-12345-12345.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  try {
    const { userId, b } = await mine(number);
    await rpc('renter_save_details', { p_by: userId, p_booking: b.id, p_details: { ...d, licence_number: d.licence_number.toUpperCase() } }, SR);
    if (b.status === 'pending_payment' && b.agreement?.status === 'open') await openAgreement(b.id, userId);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function prepareAgreement(number: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    await openAgreement(b.id, userId);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

function pngBytes(dataUrl: string): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl ?? '');
  if (!m) return null;
  const bin = Uint8Array.from(atob(m[1]!), (c) => c.charCodeAt(0));
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bin.length > 200 && bin.length < 400_000 && sig.every((v, i) => bin[i] === v) ? bin : null;
}

export interface SignInput { typedName?: string; drawn?: string; consents: string[]; sha: string }

async function signatureArgs(input: SignInput, owner: string) {
  const all = consents();
  const need = all.map((c) => c.code);
  const ticked = new Set(input.consents ?? []);
  return { all, need, ticked, owner };
}

export async function signAgreement(number: string, input: SignInput): Promise<R> {
  let target = '';
  try {
    const { userId, b } = await mine(number);
    const { all, need, ticked } = await signatureArgs(input, userId);
    if (!need.every((c) => ticked.has(c))) return { ok: false, code: 'invalid', message: 'Tick all four statements to sign.', fieldErrors: { consents: 'Tick all four statements.' } };
    if (!b.agreement || b.agreement.status !== 'open') return fail('There is no agreement waiting for your signature. Reload the page.');
    let drawnPath: string | null = null;
    if (input.drawn) {
      const png = pngBytes(input.drawn);
      if (!png) return { ok: false, code: 'invalid', message: 'Please sign your name in the box.', fieldErrors: { signature: 'Please sign your name.' } };
      drawnPath = `bookings/${b.id}/signatures/renter-${crypto.randomUUID()}.png`;
      await (await storage()).put('agreements', drawnPath, png, 'image/png');
    } else if (!(input.typedName ?? '').trim()) {
      return { ok: false, code: 'invalid', message: 'Sign by drawing or by typing your full legal name.', fieldErrors: { signature: 'Sign by drawing or typing your name.' } };
    }
    const meta = await requestMeta();
    await rpc('renter_sign_agreement', {
      p_booking: b.id, p_by: userId, p_typed_name: input.typedName?.trim() || undefined, p_drawn_signature: drawnPath ?? undefined,
      p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent, p_consent_text: SIGN_STATEMENT, p_document_sha256: input.sha,
      p_consents: all.map((c) => ({ code: c.code, version: CONSENT_VERSION, text: consentLine(c) }))
    }, SR);
    refresh(number);
    target = bookingPath(number, 'pay');
  } catch (e) { return fail(dbMessage(e)); }
  redirect(target);
}

/** An additional driver's own link: no account, the signed token names their signer row. */
export async function signAsDriver(token: string, input: SignInput): Promise<R> {
  const t = await readToken<{ s: string }>('driver-sign', token);
  if (!t) return fail('This link has expired. Ask the renter to send a new one.', 'expired');
  const all = consents().filter((c) => c.n <= 3);
  const ticked = new Set(input.consents ?? []);
  if (!all.every((c) => ticked.has(c.code))) return { ok: false, code: 'invalid', message: 'Tick the three statements to accept.', fieldErrors: { consents: 'Tick the three statements.' } };
  try {
    let drawnPath: string | null = null;
    if (input.drawn) {
      const png = pngBytes(input.drawn);
      if (!png) return { ok: false, code: 'invalid', message: 'Please sign your name in the box.', fieldErrors: { signature: 'Please sign your name.' } };
      drawnPath = `drivers/${t.s}/signature-${crypto.randomUUID()}.png`;
      await (await storage()).put('agreements', drawnPath, png, 'image/png');
    }
    const meta = await requestMeta();
    await rpc('driver_sign_agreement', {
      p_signer: t.s, p_typed_name: input.typedName?.trim() || undefined, p_drawn_signature: drawnPath ?? undefined, p_ip: meta.ip ?? undefined,
      p_user_agent: meta.userAgent, p_consent_text: SIGN_STATEMENT, p_document_sha256: input.sha,
      p_consents: all.map((c) => ({ code: c.code, version: CONSENT_VERSION, text: consentLine(c) }))
    }, SR);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- payment
export interface StartedPayment { provider: 'stripe' | 'fake'; intentId: string; clientSecret: string; amountCents: number; publishableKey: string | null; legalName: string }

export async function startPayment(number: string): Promise<R<StartedPayment>> {
  try {
    const { b } = await mine(number);
    if (b.status !== 'pending_payment') return fail(b.status === 'confirmed' ? 'This booking is already confirmed.' : reasonMessage('not_awaiting_payment'), b.status === 'confirmed' ? 'confirmed' : 'pushed_back');
    const f = await paymentFacts(b.id);
    if (!f.agreement_signed) return fail('Sign the rental agreement first.', 'unsigned');
    if (f.renter_due_at_booking_cents <= 0) return fail('Nothing is due now. We will confirm the booking on your signature.', 'nothing_due');
    // the car may already be confirmed for someone else: then nothing is authorized (section 6)
    if (!f.vehicle_free) return fail(reasonMessage('vehicle_taken'), 'pushed_back');
    const i = await bookingIntent(f);
    const p = await payments();
    return { ok: true, data: { provider: p.name, intentId: i.id, clientSecret: i.clientSecret ?? '', amountCents: i.amountCents, publishableKey: env().NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null, legalName: f.legal_name } };
  } catch (e) { return fail(dbMessage(e)); }
}

/** Fake adapter only: what Stripe's frame does in the browser. */
export async function fakeConfirmCard(number: string, intentId: string, card: { number: string; name: string; exp: string }): Promise<R<{ status: string; error: string | null }>> {
  const fake = await fakeOnly();
  if (!fake) return fail('Not available.');
  try {
    const { b } = await mine(number);
    const i = await fake.retrieveIntent(intentId);
    if (i.metadata.booking_id !== b.id) return fail('Not available.');
    const [mm, yy] = (card.exp ?? '').split('/').map((x) => Number(x.trim()));
    if (!mm || mm > 12 || !yy) return { ok: false, code: 'invalid', message: 'Check the expiry date (MM / YY).', fieldErrors: { exp: 'Use MM / YY.' } };
    const r = await fake.confirm(intentId, { number: card.number, name: card.name, expMonth: mm, expYear: 2000 + (yy % 100) });
    return { ok: true, data: { status: r.status, error: r.lastError } };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function finalizePayment(number: string, intentId: string): Promise<R<SettleResult>> {
  try {
    const { userId, b } = await mine(number);
    const i = await (await payments()).retrieveIntent(intentId);
    if (i.metadata.booking_id !== b.id) return fail('This payment is not for this booking.');
    const r = await settleIntent(intentId, userId, null);
    refresh(number);
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- self-service
export async function cancelBooking(number: string, typed: string): Promise<R<{ refundCents: number | null }>> {
  if ((typed ?? '').trim().toUpperCase() !== number.toUpperCase()) return { ok: false, code: 'invalid', message: `Type ${number} to confirm.`, fieldErrors: { confirm: `Type ${number}.` } };
  try {
    const { userId, b } = await mine(number);
    const r = (await rpc('renter_cancel_booking', { p_booking: b.id, p_by: userId, p_note: 'Cancelled in the renter portal' }, SR)) as unknown as { refund_cents?: number };
    refresh(number);
    return { ok: true, data: { refundCents: r?.refund_cents ?? null } };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function previewExtension(number: string, newReturn: string): Promise<R<Record<string, unknown>>> {
  try {
    const user = await requireUser();
    const b = await findBooking(user, number);
    if (!b) return fail('Booking not found');
    const p = (await rpc('my_extension_preview', { p_booking: b.id, p_new_return: newReturn }, { role: 'authenticated', userId: user.id })) as unknown as Record<string, unknown>;
    return { ok: true, data: p };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function requestExtension(number: string, newReturn: string, note: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    await rpc('renter_request_extension', { p_booking: b.id, p_by: userId, p_new_return: newReturn, p_note: (note ?? '').trim().slice(0, 500) || undefined }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function payExtension(number: string, extensionId: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    const f = (await rpc('server_extension_payment_facts', { p_extension: extensionId, p_by: userId }, SR)) as unknown as { status: string; total_cents: number; booking_id: string; card_on_file: { method_id: string; customer_id: string } | null };
    if (f.booking_id !== b.id) return fail('Not found');
    if (f.status !== 'approved') return fail('This extension is not waiting for payment.');
    if (!f.card_on_file?.method_id || !f.card_on_file.customer_id) return fail('No Card on File. Call us to pay for the extension.');
    const i = await (await payments()).chargeOffSession({ customerId: f.card_on_file.customer_id, paymentMethodId: f.card_on_file.method_id, amountCents: f.total_cents, description: `Extension of ${number}`, metadata: { booking_id: b.id, extension_id: extensionId, purpose: 'extension' }, idempotencyKey: `extension:${extensionId}` });
    if (i.status !== 'succeeded') return fail(i.lastError ?? 'The card was declined. Nothing was charged.');
    const r = (await rpc('server_confirm_extension_payment', { p_extension: extensionId, p_processor: { processor: 'stripe', payment_id: i.id, charge_id: i.chargeId, customer_id: i.customerId, method_id: i.paymentMethodId }, p_amount_cents: i.amountCents, p_by: userId }, SR)) as unknown as { ok?: boolean; message?: string };
    if (r && r.ok === false) return fail(r.message ?? 'The extension could not be confirmed.');
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function previewChange(number: string, changes: { pickup_at: string; return_at: string }): Promise<R<Record<string, unknown>>> {
  try {
    const user = await requireUser();
    const b = await findBooking(user, number);
    if (!b) return fail('Booking not found');
    const p = (await rpc('my_booking_change_preview', { p_booking: b.id, p_changes: changes }, { role: 'authenticated', userId: user.id })) as unknown as Record<string, unknown>;
    return { ok: true, data: p };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function requestChange(number: string, changes: { pickup_at: string; return_at: string }, note: string): Promise<R> {
  const n = (note ?? '').trim();
  if (n.length > 500) return { ok: false, code: 'invalid', message: 'Keep the note under 500 characters.', fieldErrors: { note: 'Up to 500 characters.' } };
  try {
    const { userId, b } = await mine(number);
    await rpc('renter_request_booking_change', { p_booking: b.id, p_by: userId, p_changes: changes, p_note: n || undefined }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function withdrawChange(number: string, requestId: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    if (!b.change_requests.some((c) => c.id === requestId)) return fail('Not found');
    await rpc('renter_withdraw_booking_change', { p_request: requestId, p_by: userId }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function agreeChange(number: string, requestId: string): Promise<R> {
  try {
    const { userId, b } = await mine(number);
    if (!b.change_requests.some((c) => c.id === requestId)) return fail('Not found');
    const meta = await requestMeta();
    await rpc('renter_agree_booking_change', { p_request: requestId, p_by: userId, p_ip: (meta.ip ?? null) as string, p_user_agent: meta.userAgent }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- identity and coverage uploads
const KINDS = ['licence_front', 'licence_back', 'selfie', 'coverage_proof'] as const;
type Kind = typeof KINDS[number];
const TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };
const MAX_BYTES = 10 * 1024 * 1024;

export async function createUpload(number: string, kind: Kind, driverId: string | null, contentType: string, size: number): Promise<R<{ url: string; headers: Record<string, string>; ticket: string }>> {
  try {
    const { userId, b } = await mine(number);
    if (!KINDS.includes(kind)) return fail('Unknown upload.');
    if (!TYPES[contentType] || (contentType === 'application/pdf' && kind !== 'coverage_proof')) return fail(kind === 'coverage_proof' ? 'Upload a photo or a PDF.' : 'Upload a photo (JPEG or PNG).');
    if (!(size > 0 && size <= MAX_BYTES)) return fail('The file must be under 10 MB.');
    if (!['pending_payment', 'confirmed'].includes(b.status)) return fail('Documents are uploaded once the offer is approved.');
    if (kind === 'coverage_proof' ? driverId !== null : !b.drivers.some((d) => d.driver_id === driverId)) return fail('That driver is not on this booking.');
    const bucket: Bucket = kind === 'coverage_proof' ? 'documents' : 'identity';
    const key = `renters/${userId}/${b.id}/${kind}-${driverId ?? 'booking'}-${crypto.randomUUID()}.${TYPES[contentType]}`;
    const up = await (await storage()).signedUploadUrl(bucket, key, contentType, 300);
    const ticket = await signToken('upload', { b: b.id, n: number, k: kind, d: driverId, key, bucket, ct: contentType, u: userId }, 300);
    return { ok: true, data: { ...up, ticket } };
  } catch (e) { return fail(dbMessage(e)); }
}

function magicOk(bytes: Uint8Array, ct: string): boolean {
  const s = (sig: number[]) => sig.every((v, i) => bytes[i] === v);
  if (ct === 'image/jpeg') return s([0xff, 0xd8, 0xff]);
  if (ct === 'image/png') return s([0x89, 0x50, 0x4e, 0x47]);
  if (ct === 'application/pdf') return s([0x25, 0x50, 0x44, 0x46]);
  return false;
}

export async function confirmUpload(ticket: string, details: Record<string, string> | null): Promise<R> {
  const t = await readToken<{ b: string; n: string; k: Kind; d: string | null; key: string; bucket: Bucket; ct: string; u: string }>('upload', ticket);
  if (!t) return fail('The upload link expired. Choose the file again.', 'expired');
  const user = await requireUser();
  if (user.id !== t.u) return fail('Not permitted');
  const s = await storage();
  const bytes = await s.get(t.bucket, t.key);
  if (!bytes) return fail('The file did not arrive. Try again.');
  // the real type and size, checked after upload (13-security.md section 7); a mismatch is deleted
  if (bytes.byteLength > MAX_BYTES || !magicOk(bytes, t.ct)) {
    await s.remove(t.bucket, t.key);
    return fail('That file is not a photo or PDF we can read. Try another.');
  }
  try {
    const d = details ?? {};
    const clean: Record<string, string> = {};
    for (const k of ['coverage_option', 'insurer_name', 'policy_number', 'policy_expiry', 'card_issuer', 'card_last4']) if (d[k]) clean[k] = String(d[k]).slice(0, 120);
    const r = (await rpc('renter_register_upload', { p_booking: t.b, p_by: user.id, p_kind: t.k, p_driver: t.d ?? undefined, p_storage_path: t.key, p_sha256: await sha256Hex(bytes), p_mime_type: t.ct, p_details: clean, p_storage_bucket: t.bucket }, SR)) as unknown as { ok: boolean; error?: string };
    if (!r.ok) { await s.remove(t.bucket, t.key); return fail('Too many uploads in the last hour. Try again later.', 'rate_limited'); }
    refresh(t.n);
    return { ok: true, data: null };
  } catch (e) {
    await s.remove(t.bucket, t.key);
    return fail(dbMessage(e));
  }
}

// ---------------------------------------------------------------- notifications and profile
export async function markRead(ids: string[] | null): Promise<R> {
  try {
    const user = await requireUser('/account/notifications');
    await rpc('mark_notifications_read', { p_ids: ids && ids.length ? ids : undefined }, { role: 'authenticated', userId: user.id });
    revalidatePath('/account/notifications');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function setPreference(code: string, email: boolean, inApp: boolean): Promise<R> {
  try {
    const user = await requireUser('/account/notifications');
    await rpc('set_notification_preference', { p_code: code, p_email: email, p_in_app: inApp }, { role: 'authenticated', userId: user.id });
    revalidatePath('/account/notifications');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function setMarketing(optIn: boolean): Promise<R> {
  try {
    const user = await requireUser('/account/notifications');
    const meta = await requestMeta();
    const c = (await consentTexts()).marketing;
    await rpc('renter_set_marketing', { p_by: user.id, p_opt_in: optIn, p_text: c.text, p_version: c.version, p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent }, SR);
    revalidatePath('/account/notifications');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export interface ProfileInput { mobile: string; address_line1: string; address_line2?: string; city: string; province: string; postal_code: string; country: string }
export async function saveProfile(p: ProfileInput): Promise<R> {
  const digits = (p.mobile ?? '').replace(/[^\d+]/g, '');
  const mobile = digits.startsWith('+') ? digits : digits.length === 10 ? `+1${digits}` : digits.length === 11 && digits.startsWith('1') ? `+${digits}` : digits;
  const fe: Record<string, string> = {};
  if (!/^\+[1-9]\d{7,14}$/.test(mobile)) fe.mobile = 'Enter a mobile number, for example 647-555-0142.';
  for (const k of ['address_line1', 'city', 'province', 'postal_code', 'country'] as const) if (!String(p[k] ?? '').trim()) fe[k] = 'Required.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  try {
    const user = await requireUser('/account/profile');
    await rpc('renter_save_details', { p_by: user.id, p_details: { ...p, mobile } }, SR);
    revalidatePath('/account/profile');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- messages on the booking (migration 0033)
/** The renter writes in the booking's messages: customer service gets a task and a notice. */
export async function sendBookingMessage(number: string, body: string): Promise<R> {
  const t = (body ?? '').trim();
  if (t.length < 2 || t.length > 4000) return { ok: false, code: 'invalid', message: 'Write your message (up to 4,000 characters).', fieldErrors: { body: 'Write your message.' } };
  try {
    const { userId, b } = await mine(number);
    await rpc('renter_send_message', { p_booking: b.id, p_by: userId, p_body: t }, SR);
    refresh(number);
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}
