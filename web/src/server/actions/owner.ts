'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { fakeOnly, payments } from '@/integrations/payments';
import { storage } from '@/integrations/storage';
import type { ActionResult } from '@/features/forms/schemas';
import { CONFIRMATIONS, OWNER_SIGN_STATEMENT, type PacketKey } from '@/features/owner-agreement/model';
import { requestMeta } from '@/server/request';
import { readToken, sha256Hex, signToken } from '@/server/links';
import { encryptField, PAYOUT_KEY_VERSION } from '@/server/crypto';
import { ownerHome, requireOwnerUser } from '@/server/owner/data';
import { attachOwnerSignedCopies, openOwnerPacket, type SignedResult } from '@/server/owner/agreements';
import { invoiceFacts, invoiceIdFor, invoiceIntent, publishableKey, settleInvoiceIntent, type InvoiceSettle, type StartedInvoicePayment } from '@/server/owner/payment';

// Every owner action: a server action run for the signed-in user. The database checks again that
// the user is the owner of what is touched (p_by); nothing is taken from the browser on trust.
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
const fail = (message: string, code = 'refused'): { ok: false; code: string; message: string } => ({ ok: false, code, message });
const dbMessage = (e: unknown, fallback = 'Something went wrong. Please try again or call us.') => (e instanceof DbError ? e.message : fallback);
const invalid = (fieldErrors: Record<string, string>, message = 'Check the highlighted fields.') => ({ ok: false as const, code: 'invalid', message, fieldErrors });

async function owner() {
  const user = await requireOwnerUser();
  const home = await ownerHome(user);
  if (!home) throw new DbError('This account is not an owner account.', '42501');
  return { user, home };
}

// ---------------------------------------------------------------- paying an invoice
async function myInvoice(number: string, userId: string) {
  const id = await invoiceIdFor(number);
  if (!id) throw new DbError('Invoice not found', 'P0002');
  return invoiceFacts(id, userId);
}

export async function startInvoicePayment(number: string, method: 'card' | 'acss_debit'): Promise<R<StartedInvoicePayment>> {
  try {
    const { user, home } = await owner();
    const f = await myInvoice(number, user.id);
    if (f.owner_id !== home.owner.id) return fail('Invoice not found');
    if (f.status === 'paid') return fail('This invoice is paid. Thank you.', 'paid');
    if (f.pending) return fail('A payment for this invoice is already processing. We will email you when it clears.', 'pending');
    if (!f.payable) return fail('This invoice cannot be paid online. Call us and we will help.', 'not_payable');
    if (method !== 'card' && method !== 'acss_debit') return fail('Choose card or pre-authorized debit.');
    const i = await invoiceIntent(f, method, home.owner.owner_type);
    const p = await payments();
    return { ok: true, data: { provider: p.name, intentId: i.id, clientSecret: i.clientSecret ?? '', amountCents: i.amountCents, method, publishableKey: publishableKey(), ownerName: home.owner.owner_type === 'corporation' ? home.owner.corporation_name ?? home.owner.legal_name : home.owner.legal_name, ownerEmail: home.owner.email ?? user.email } };
  } catch (e) { return fail(dbMessage(e)); }
}

async function ownIntent(number: string, intentId: string) {
  const { user } = await owner();
  const f = await myInvoice(number, user.id);
  const i = await (await payments()).retrieveIntent(intentId);
  if (i.metadata.owner_invoice_id !== f.id) throw new DbError('This payment is not for this invoice.', '42501');
  return { user, f };
}

/** Fake adapter only: what Stripe's card frame does in the browser. */
export async function fakeConfirmInvoiceCard(number: string, intentId: string, card: { number: string; name: string; exp: string }): Promise<R<{ status: string; error: string | null }>> {
  const fake = await fakeOnly();
  if (!fake) return fail('Not available.');
  try {
    await ownIntent(number, intentId);
    const [mm, yy] = (card.exp ?? '').split('/').map((x) => Number(x.trim()));
    if (!mm || mm > 12 || !yy) return invalid({ exp: 'Use MM / YY.' }, 'Check the expiry date (MM / YY).');
    const r = await fake.confirm(intentId, { number: card.number, name: card.name, expMonth: mm, expYear: 2000 + (yy % 100) });
    return { ok: true, data: { status: r.status, error: r.lastError } };
  } catch (e) { return fail(dbMessage(e)); }
}

/** Fake adapter only: what Stripe's bank form does for a pre-authorized debit (the mandate is accepted, the debit submitted). */
export async function fakeConfirmInvoiceDebit(number: string, intentId: string, bank: { name: string; institution: string; transit: string; account: string }): Promise<R<{ status: string; error: string | null }>> {
  const fake = await fakeOnly();
  if (!fake) return fail('Not available.');
  try {
    await ownIntent(number, intentId);
    const r = await fake.confirmDebit(intentId, { name: bank.name, institution: bank.institution.trim(), transit: bank.transit.trim(), account: bank.account.replace(/\s/g, '') });
    return { ok: true, data: { status: r.status, error: r.lastError } };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function finalizeInvoicePayment(number: string, intentId: string): Promise<R<InvoiceSettle>> {
  try {
    const { user } = await ownIntent(number, intentId);
    const r = await settleInvoiceIntent(intentId, user.id);
    revalidatePath(`/owner/invoices/${number}`); revalidatePath('/owner/invoices'); revalidatePath('/owner');
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- agreements
export async function prepareOwnerAgreements(): Promise<R<{ docs: Array<{ key: PacketKey; sha: string }> }>> {
  try {
    const { user, home } = await owner();
    const { docs } = await openOwnerPacket(home.owner.id, user.id);
    return { ok: true, data: { docs: docs.map((d) => ({ key: d.key, sha: d.sha })) } };
  } catch (e) { return fail(dbMessage(e)); }
}

function pngBytes(dataUrl: string): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl ?? '');
  if (!m) return null;
  const bin = Uint8Array.from(atob(m[1]!), (c) => c.charCodeAt(0));
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bin.length > 200 && bin.length < 400_000 && sig.every((v, i) => bin[i] === v) ? bin : null;
}

export interface OwnerSignInput { docs: Array<{ key: PacketKey; sha: string }>; initials: string; confirmations: string[]; typedName?: string; drawn?: string }

export async function signOwnerAgreements(input: OwnerSignInput): Promise<R> {
  let target = '';
  try {
    const { user, home } = await owner();
    const fe: Record<string, string> = {};
    const initials = (input.initials ?? '').trim().toUpperCase();
    const needsInitials = input.docs.some((d) => d.key === 'enrollment');
    if (needsInitials && !/^[A-Z]{1,4}$/.test(initials)) fe.initials = 'Type your initials (letters only).';
    if (needsInitials && !CONFIRMATIONS.every((c) => (input.confirmations ?? []).includes(c.code))) fe.confirmations = 'Initial all three confirmations.';
    let drawnPath: string | null = null;
    if (input.drawn) {
      const png = pngBytes(input.drawn);
      if (!png) fe.signature = 'Please sign your name in the box.';
      else {
        drawnPath = `owners/${home.owner.id}/signatures/owner-${crypto.randomUUID()}.png`;
        if (!Object.keys(fe).length) await (await storage()).put('agreements', drawnPath, png, 'image/png');
      }
    } else if (!(input.typedName ?? '').trim()) fe.signature = 'Sign by drawing or by typing your full legal name.';
    if (Object.keys(fe).length) return invalid(fe);
    const meta = await requestMeta();
    const res = (await rpc('owner_sign_agreements', {
      p_owner: home.owner.id, p_by: user.id,
      p: {
        typed_name: input.typedName?.trim() || null, drawn_signature: drawnPath, ip: meta.ip, user_agent: meta.userAgent, consent_text: OWNER_SIGN_STATEMENT,
        initials: needsInitials ? Object.fromEntries(CONFIRMATIONS.map((c) => [c.code, initials])) : null,
        documents: input.docs.map((d) => ({ key: d.key, sha256: d.sha }))
      }
    }, SR)) as unknown as SignedResult;
    try { await attachOwnerSignedCopies(home.owner.id, user.id, res); } catch (e) { console.error('owner signed copy', e); }
    revalidatePath('/owner'); revalidatePath('/owner/documents');
    target = '/owner?signed=1';
  } catch (e) { return fail(dbMessage(e)); }
  redirect(target);
}

// ---------------------------------------------------------------- banking, profile, exit, own booking
export interface PayoutInput { method: 'bank_transfer' | 'e_transfer'; account_holder?: string; institution_no?: string; transit_no?: string; account_no?: string; e_transfer_email?: string }

export async function submitPayoutAccount(p: PayoutInput): Promise<R> {
  const fe: Record<string, string> = {};
  if (p.method === 'bank_transfer') {
    if (!/^\d{3}$/.test(p.institution_no ?? '')) fe.institution_no = 'The institution number is 3 digits.';
    if (!/^\d{5}$/.test(p.transit_no ?? '')) fe.transit_no = 'The transit number is 5 digits.';
    if (!/^\d{7,12}$/.test((p.account_no ?? '').replace(/\s/g, ''))) fe.account_no = 'The account number is 7 to 12 digits.';
  } else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(p.e_transfer_email ?? '')) fe.e_transfer_email = 'Enter the email address for e-Transfers.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const { user } = await owner();
    const account = (p.account_no ?? '').replace(/\s/g, '');
    await rpc('owner_submit_payout_account', { p_by: user.id, p: p.method === 'bank_transfer'
      ? { method: 'bank_transfer', account_holder: p.account_holder?.trim() || null, institution_no: p.institution_no, transit_no: p.transit_no,
          account_no: await encryptField(account), account_last4: account.slice(-4), key_version: PAYOUT_KEY_VERSION }
      : { method: 'e_transfer', e_transfer_email: p.e_transfer_email?.trim() } }, SR);
    revalidatePath('/owner/banking');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export interface OwnerProfileInput { email: string; phone: string; address_line1: string; address_line2?: string; city: string; province: string; postal_code: string; hst_number?: string }
export async function saveOwnerProfile(p: OwnerProfileInput): Promise<R> {
  const fe: Record<string, string> = {};
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(p.email ?? '')) fe.email = 'Enter an email address.';
  const digits = (p.phone ?? '').replace(/[^\d+]/g, '');
  const phone = digits.startsWith('+') ? digits : digits.length === 10 ? `+1${digits}` : digits.length === 11 && digits.startsWith('1') ? `+${digits}` : digits;
  if (!/^\+[1-9]\d{7,14}$/.test(phone)) fe.phone = 'Enter a phone number, for example 647-555-0142.';
  for (const k of ['address_line1', 'city', 'province', 'postal_code'] as const) if (!String(p[k] ?? '').trim()) fe[k] = 'Required.';
  if (p.hst_number && !/^\d{9}RT\d{4}$/i.test(p.hst_number.replace(/\s/g, ''))) fe.hst_number = 'An HST number looks like 123456789RT0001.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const { user } = await owner();
    await rpc('owner_save_profile', { p_by: user.id, p: { ...p, phone, hst_number: p.hst_number?.replace(/\s/g, '') || null } }, SR);
    revalidatePath('/owner/profile');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function giveExitNotice(vehicleId: string, reason: string, returnTo: string, confirmed: boolean): Promise<R<{ exit_date: string; retransfer_fees_paid_by: string }>> {
  if (!confirmed) return invalid({ confirm: 'Tick the box to confirm.' });
  try {
    const { user, home } = await owner();
    if (!home.vehicles.some((v) => v.vehicle_id === vehicleId)) return fail('Vehicle not found');
    const r = (await rpc('owner_give_exit_notice', { p_by: user.id, p_vehicle: vehicleId, p: { reason: reason.trim().slice(0, 500), return_registration_to: returnTo.trim().slice(0, 300) } }, SR)) as unknown as { exit_date: string; retransfer_fees_paid_by: string };
    revalidatePath('/owner'); revalidatePath(`/owner/vehicles/${vehicleId}`);
    return { ok: true, data: r };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function withdrawExitNotice(exitId: string): Promise<R> {
  try {
    const { user, home } = await owner();
    if (!home.exits.some((x) => x.id === exitId)) return fail('Notice not found');
    await rpc('owner_withdraw_exit_notice', { p_by: user.id, p_exit: exitId }, SR);
    revalidatePath('/owner');
    return { ok: true, data: null };
  } catch (e) { return fail(dbMessage(e)); }
}

export async function bookOwnCar(vehicleId: string, pickup: string, ret: string, note: string): Promise<R<{ bookingNumber: string }>> {
  const a = new Date(pickup), b = new Date(ret);
  if (isNaN(a.getTime()) || isNaN(b.getTime())) return invalid({ pickup: 'Choose the pickup and return.' });
  if (b <= a) return invalid({ ret: 'The return must be after the pickup.' });
  if ((b.getTime() - a.getTime()) / 864e5 > 30) return invalid({ ret: 'An Owner Booking is 30 days at most.' });
  try {
    const { user, home } = await owner();
    if (!home.vehicles.some((v) => v.vehicle_id === vehicleId)) return fail('Vehicle not found');
    const id = (await rpc('owner_book_own_vehicle', { p_by: user.id, p_vehicle: vehicleId, p_pickup: a.toISOString(), p_return: b.toISOString(), p_note: note.trim().slice(0, 500) || undefined }, SR)) as unknown as string;
    // the Owner Booking is the owner's own booking as a renter: it is followed in /account like any other
    const rows = ((await rpc('my_bookings', {}, { role: 'authenticated', userId: user.id })) ?? []) as unknown as Array<{ id: string; booking_number: string }>;
    revalidatePath('/owner/bookings');
    return { ok: true, data: { bookingNumber: rows.find((x) => x.id === id)?.booking_number ?? '' } };
  } catch (e) { return fail(dbMessage(e)); }
}

// ---------------------------------------------------------------- vehicle documents (ownership permit, lender permission, insurance)
const DOC_KINDS = ['ownership_permit', 'finance_party_permission', 'owner_insurance_proof'] as const;
type DocKind = typeof DOC_KINDS[number];
const TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };
const MAX_BYTES = 10 * 1024 * 1024;

export async function createOwnerUpload(vehicleId: string, kind: DocKind, contentType: string, size: number): Promise<R<{ url: string; headers: Record<string, string>; ticket: string }>> {
  try {
    const { user, home } = await owner();
    if (!home.vehicles.some((v) => v.vehicle_id === vehicleId)) return fail('Vehicle not found');
    if (!DOC_KINDS.includes(kind)) return fail('Unknown upload.');
    if (!TYPES[contentType]) return fail('Upload a photo or a PDF.');
    if (!(size > 0 && size <= MAX_BYTES)) return fail('The file must be under 10 MB.');
    const key = `owners/${home.owner.id}/vehicles/${vehicleId}/${kind}-${crypto.randomUUID()}.${TYPES[contentType]}`;
    const up = await (await storage()).signedUploadUrl('documents', key, contentType, 300);
    const ticket = await signToken('owner-upload', { v: vehicleId, k: kind, key, ct: contentType, u: user.id }, 300);
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

export async function confirmOwnerUpload(ticket: string): Promise<R> {
  const t = await readToken<{ v: string; k: DocKind; key: string; ct: string; u: string }>('owner-upload', ticket);
  if (!t) return fail('The upload link expired. Choose the file again.', 'expired');
  const user = await requireOwnerUser();
  if (user.id !== t.u) return fail('Not permitted');
  const s = await storage();
  const bytes = await s.get('documents', t.key);
  if (!bytes) return fail('The file did not arrive. Try again.');
  if (bytes.byteLength > MAX_BYTES || !magicOk(bytes, t.ct)) { await s.remove('documents', t.key); return fail('That file is not a photo or PDF we can read. Try another.'); }
  try {
    await rpc('owner_register_document', { p_by: user.id, p_vehicle: t.v, p_kind: t.k, p_path: t.key, p_sha256: await sha256Hex(bytes), p_mime: t.ct }, SR);
    revalidatePath(`/owner/vehicles/${t.v}`); revalidatePath('/owner');
    return { ok: true, data: null };
  } catch (e) { await s.remove('documents', t.key); return fail(dbMessage(e)); }
}
