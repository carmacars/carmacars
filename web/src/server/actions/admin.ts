'use server';
import { revalidatePath } from 'next/cache';
import { env } from '@/lib/env';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { assertAdmin } from '@/server/admin/data';
import { signToken } from '@/server/links';

// Admin actions for the owner billing flow (the full admin portal comes next). Each re-checks the
// Admin (and two-step sign-in when required) and the database checks the Admin again (p_admin).
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
const fail = (e: unknown) => ({ ok: false as const, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message : 'Something went wrong.' });
const invalid = (fieldErrors: Record<string, string>, message = 'Check the highlighted fields.') => ({ ok: false as const, code: 'invalid', message, fieldErrors });
const refresh = (ownerId: string) => { revalidatePath(`/admin/owners/${ownerId}`); revalidatePath('/admin/owners'); revalidatePath('/admin/invoices'); };
const cents = (v: string) => Math.round(Number(String(v).replace(/[$,\s]/g, '')) * 100);

export interface TermsInput { management_mode: string; onboarding_method: string; insurance: string; tracker: string; share: string; install: string; special_terms: string }

export async function setVehicleTerms(ownerId: string, vehicleId: string, t: TermsInput): Promise<R<{ status: string }>> {
  const fe: Record<string, string> = {};
  const ins = cents(t.insurance), trk = cents(t.tracker), inst = cents(t.install), share = Math.round(Number(t.share) * 100);
  if (!Number.isFinite(ins) || ins < 0) fe.insurance = 'Enter an amount.';
  if (!Number.isFinite(trk) || trk < 0) fe.tracker = 'Enter an amount.';
  if (!Number.isFinite(inst) || inst < 0) fe.install = 'Enter an amount.';
  if (!Number.isFinite(share) || share < 0 || share > 10000) fe.share = 'A percentage from 0 to 100.';
  if (!t.onboarding_method) fe.onboarding_method = 'Choose the method.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const admin = await assertAdmin();
    const r = (await rpc('admin_set_vehicle_terms', { p_vehicle: vehicleId, p_admin: admin.id, p_terms: {
      management_mode: t.management_mode, onboarding_method: t.onboarding_method, insurance_fee_cents: ins, tracker_fee_cents: trk,
      revenue_share_bps: share, install_fee_cents: inst, special_terms: t.special_terms.trim() || null } }, SR)) as unknown as { status: string };
    refresh(ownerId);
    return { ok: true, data: { status: r.status } };
  } catch (e) { return fail(e); }
}

export async function approveVehicleTerms(ownerId: string, vehicleId: string, approve: boolean): Promise<R> {
  try {
    const admin = await assertAdmin();
    await rpc('admin_approve_vehicle_terms', { p_vehicle: vehicleId, p_admin: admin.id, p_approve: approve }, SR);
    refresh(ownerId);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

export async function issueUpfrontInvoices(ownerId: string, vehicleIds: string[] | null): Promise<R<{ count: number }>> {
  try {
    const admin = await assertAdmin();
    const r = (await rpc('admin_issue_upfront_invoices', { p_owner: ownerId, p_admin: admin.id, p_vehicles: vehicleIds && vehicleIds.length ? vehicleIds : undefined }, SR)) as unknown as unknown[];
    refresh(ownerId);
    return { ok: true, data: { count: r.length } };
  } catch (e) { return fail(e); }
}

export interface OfflineInput { method: string; reference: string; received_on: string; amount: string; note: string }
export async function recordOfflinePayment(ownerId: string, invoiceId: string, p: OfflineInput): Promise<R<{ status: string }>> {
  const fe: Record<string, string> = {};
  if (!['e_transfer', 'cheque', 'bank_transfer'].includes(p.method)) fe.method = 'Choose how it was paid.';
  if ((p.reference ?? '').trim().length < 3) fe.reference = 'Enter the e-Transfer reference or the cheque number.';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(p.received_on ?? '')) fe.received_on = 'Enter the date received.';
  const amount = p.amount?.trim() ? cents(p.amount) : null;
  if (amount !== null && (!Number.isFinite(amount) || amount <= 0)) fe.amount = 'Enter the amount received, or leave it empty for the balance.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const admin = await assertAdmin();
    const r = (await rpc('admin_record_owner_offline_payment', { p_invoice: invoiceId, p_admin: admin.id, p: {
      method: p.method, reference: p.reference.trim(), received_on: p.received_on, amount_cents: amount, note: p.note.trim() || null } }, SR)) as unknown as { invoice_status: string };
    refresh(ownerId);
    return { ok: true, data: { status: r.invoice_status } };
  } catch (e) { return fail(e); }
}

/** An invitation to apply (a new owner) or a sign-in link to the owner portal (an owner on file). */
export async function sendOwnerLink(kind: 'invite' | 'portal', email: string, name: string): Promise<R<{ url: string }>> {
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email ?? '')) return invalid({ email: 'Enter the owner\'s email address.' });
  try {
    await assertAdmin();
    const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
    const url = kind === 'invite'
      ? `${base}/list-your-car/apply?invite=${await signToken('owner-invite', { e: email.trim().toLowerCase(), n: name.trim() }, 14 * 86400)}`
      : `${base}/sign-in?next=${encodeURIComponent('/owner')}`;
    await rpc('server_send_link_email', { p_email: email.trim(), p_name: name.trim(), p_url: url, p_expiry: kind === 'invite' ? '14 days' : '24 hours', p_key: `${kind}:${email.trim().toLowerCase()}:${Date.now()}` }, SR);
    return { ok: true, data: { url } };
  } catch (e) { return fail(e); }
}
