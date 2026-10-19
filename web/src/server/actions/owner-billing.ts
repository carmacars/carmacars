'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { auth } from '@/lib/auth';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';

// Negotiated terms, owner invoices, the Approve step and cars staff add for an owner (migration 0067). Every call goes
// through the staff door; the database decides who may do what (Admins; customer service and fleet add cars) and
// checks every value again.
type R<T = unknown> = ActionResult<T>;
type J = Record<string, unknown>;
const SR = { role: 'service_role' as const };
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const invalid = (fieldErrors: Record<string, string>, message = 'Check the highlighted fields.'): R<never> => ({ ok: false, code: 'invalid', message, fieldErrors });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const again = (paths: string[]) => { for (const p of paths) if (p.startsWith('/')) revalidatePath(p); };

async function act<T = J>(name: string, p: J, paths: string[] = []): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    const r = await door<T>(user.id, 'ops_do', name, p, aal);
    again(paths);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- terms
export interface TermsInput { owner_id?: string; vehicle_id?: string; effective_from?: string; insurance_fee_cents?: number | null; tracker_fee_cents?: number | null;
  revenue_share_bps?: number | null; install_fee_cents?: number | null; first_last_cents?: number | null; one_off_fees?: Array<{ description: string; amount_cents: number; hst: boolean }>;
  note?: string; confirm_resign?: boolean }
export async function saveTerms(t: TermsInput, paths: string[] = []) {
  if (t.revenue_share_bps !== undefined && t.revenue_share_bps !== null && (t.revenue_share_bps < 0 || t.revenue_share_bps > 10000)) return invalid({ share: 'Between 0% and 100%.' });
  return act<{ saved: string | null; needs_resign: boolean; message?: string; note?: string; change_id?: string }>('owner_terms_save', t as J, paths);
}
export async function scheduleChange(p: { change_id: string; do: 'paper' | 'cancel'; signed_on?: string; reason?: string }, paths: string[] = []) {
  return act('schedule_change_admin', p, paths);
}

// ---------------------------------------------------------------- invoices
export interface LineInput { kind?: string; description: string; quantity: number | string; unit_amount_cents: number; hst: boolean; note?: string }
export interface DraftInput { id?: string; vehicle_id?: string; kind?: string; title?: string; notes?: string; due_on?: string; application_id?: string; lines: LineInput[] }
export async function saveDraft(d: DraftInput, paths: string[] = []) {
  const fe: Record<string, string> = {};
  if (!d.id && !d.vehicle_id) fe.vehicle_id = 'Choose the car.';
  d.lines.forEach((l, i) => {
    if (!l.description.trim()) fe[`line-${i}-description`] = 'Write the description.';
    if (!Number.isFinite(Number(l.quantity)) || Number(l.quantity) <= 0) fe[`line-${i}-quantity`] = 'A number above 0.';
    if (!Number.isInteger(l.unit_amount_cents)) fe[`line-${i}-unit`] = 'Dollars and cents, for example 123.45.';
  });
  if (!d.lines.length) fe.lines = 'Add at least one line.';
  if (Object.keys(fe).length) return invalid(fe);
  return act<{ id: string; invoice_number: string; status: string; total_cents: number }>('owner_invoice_draft_save', { ...d, lines: d.lines.map((l) => ({ ...l, quantity: String(l.quantity) })) } as J, ['/admin/invoices', ...paths]);
}
export async function issueInvoice(id: string, paths: string[] = []) { return act('owner_invoice_issue', { id }, ['/admin/invoices', ...paths]); }
export async function voidInvoice(id: string, reason: string, reissue: boolean, paths: string[] = []) {
  if (!reason.trim()) return invalid({ reason: 'Give the reason. The owner reads it.' });
  return act<{ replacement_id: string | null; replacement_number: string | null }>('owner_invoice_void', { id, reason: reason.trim(), reissue }, ['/admin/invoices', ...paths]);
}
export async function creditNote(id: string, amountCents: number, reason: string, paths: string[] = []) {
  const fe: Record<string, string> = {};
  if (!reason.trim()) fe.reason = 'Give the reason. The owner reads it.';
  if (!Number.isInteger(amountCents) || amountCents <= 0) fe.amount = 'Enter the amount to credit, before HST.';
  if (Object.keys(fe).length) return invalid(fe);
  return act<{ invoice_number: string }>('owner_invoice_credit_note', { id, amount_cents: amountCents, reason: reason.trim() }, ['/admin/invoices', ...paths]);
}
export async function resendInvoice(id: string, paths: string[] = []) { return act('owner_invoice_resend', { id }, paths); }

// ---------------------------------------------------------------- the set-up email of a car staff entered
/** After approval: the owner's one email. An owner with no sign-in gets one made now and the link to choose a password
 *  in that same email (nothing is sent by the sign-in service). */
async function setupEmail(adminId: string, aal: 'aal1' | 'aal2' | null, applicationId: string, setup: { owner_id: string; has_account: boolean; email: string | null; name: string }, resend = false): Promise<string> {
  let passwordUrl: string | null = null;
  if (!setup.has_account && setup.email) {
    const a = await auth();
    if (a.accountLink) {
      const existing = (await rpc('server_user_by_email', { p_email: setup.email }, SR)) as unknown as string | null;
      const made = await a.accountLink(setup.email, setup.name, '/owner/review', existing);
      if (made.ok) {
        await rpc('admin_invite_account', { p_admin: adminId, p: { user_id: made.user.id, email: setup.email, full_name: setup.name, role: 'owner', owner_id: setup.owner_id } }, SR);
        passwordUrl = made.link;
      }
    }
  }
  const r = await door<{ sent: boolean }>(adminId, 'ops_do', 'owner_setup_email', { application_id: applicationId, password_url: passwordUrl, again: resend }, aal);
  return r.sent ? (passwordUrl ? 'The owner was emailed to review and sign, with the link to choose a password.' : 'The owner was emailed to review and sign.') : 'The set-up email was sent before.';
}

export async function sendSetupEmail(applicationId: string) {
  try {
    const { user, aal } = await me();
    const plan = await door<{ status: string }>(user.id, 'ops_read', 'application_approve_plan', { id: applicationId }, aal);
    if (plan.status !== 'approved') return { ok: false as const, code: 'refused', message: 'Approve the application first.' };
    const s = await door<{ owner: { id: string; legal_name: string; email: string | null; has_account: boolean } }>(user.id, 'ops_read', 'application', { id: applicationId }, aal);
    const note = await setupEmail(user.id, aal, applicationId, { owner_id: s.owner.id, has_account: s.owner.has_account, email: s.owner.email, name: s.owner.legal_name }, true);
    again([`/admin/applications/${applicationId}`]);
    return { ok: true as const, data: { note } };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- Approve: terms and the first invoices per car
export interface ApproveCar { vehicle_id: string; terms: J; invoices: J[] }
export async function approveWithTerms(applicationId: string, cars: ApproveCar[]) {
  try {
    const { user, aal } = await me();
    const r = await door<{ status: string; invoices: J[]; setup: { needed: boolean; owner_id: string; has_account: boolean; email: string | null; name: string } | null }>(
      user.id, 'ops_do', 'application_approve', { id: applicationId, cars }, aal);
    let note: string | null = null;
    if (r.setup?.needed) note = await setupEmail(user.id, aal, applicationId, r.setup).catch((e) => `Approved. The set-up email did not go: ${(fail(e) as { message: string }).message} Use "Send the set-up email" on the application.`);
    again(['/admin/applications', `/admin/applications/${applicationId}`, '/admin', '/admin/invoices']);
    return { ok: true as const, data: { ...r, note } };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- staff add a car for an owner
export async function pickOwner(q: string) {
  try {
    const { user, aal } = await me();
    const roles = await rolesOf(user.id);
    return { ok: true as const, data: await door<Array<{ id: string; legal_name: string; email: string | null; phone: string | null; cars: number }>>(user.id, roles.admin ? 'ops_read' : 'va_read', 'owner_pick', { q }, aal) };
  } catch (e) { return fail(e); }
}
export async function addCarFacts(ownerId: string | null, mode = 'managed') {
  try {
    const { user, aal } = await me();
    const roles = await rolesOf(user.id);
    return { ok: true as const, data: await door<J>(user.id, roles.admin ? 'ops_read' : 'va_read', 'owner_add_car_facts', { owner_id: ownerId, mode }, aal) };
  } catch (e) { return fail(e); }
}

const DOCS = ['ownership_permit', 'owner_insurance_proof', 'finance_party_permission'] as const;
async function fileOf(form: FormData, name: string): Promise<{ bytes: Uint8Array; type: string; ext: string } | null | string> {
  const file = form.get(name);
  if (!(file instanceof File) || file.size === 0) return null;
  if (file.size > 10_000_000) return 'The file must be under 10 MB.';
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50;
  if (!pdf && !jpg && !png) return 'Use a PDF, JPEG or PNG file.';
  return { bytes, type: pdf ? 'application/pdf' : jpg ? 'image/jpeg' : 'image/png', ext: pdf ? 'pdf' : jpg ? 'jpg' : 'png' };
}

/** form: payload (JSON: owner_id or owner, vehicle, sourced, signing, note, plan) and the files doc_<kind>. */
export async function staffAddOwnerCar(form: FormData): Promise<R<{ application_id: string; application_number: string; owner_id: string; vehicle_id: string; approved: boolean; note: string | null; docs: number }>> {
  let p: J;
  try { p = JSON.parse(String(form.get('payload') ?? '{}')) as J; } catch { return invalid({ form: 'Something went wrong. Reload the page.' }); }
  const v = (p.vehicle ?? {}) as J;
  const o = (p.owner ?? {}) as J;
  const fe: Record<string, string> = {};
  if (!p.owner_id) {
    if (!String(o.legal_name ?? '').trim()) fe.legal_name = 'Enter the owner\'s full legal name.';
    if (p.signing !== 'paper' && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(o.email ?? ''))) fe.email = 'Enter the owner\'s email: the set-up email goes there.';
    if (!String(o.phone ?? '').trim()) fe.phone = 'Enter the owner\'s phone.';
    if (o.owner_type === 'corporation' && !String(o.corporation_name ?? '').trim()) fe.corporation_name = 'Enter the corporation\'s name.';
  }
  if (!/^[A-HJ-NPR-Z0-9]{17}$/i.test(String(v.vin ?? '').trim())) fe.vin = 'Enter the 17-character VIN.';
  if (!v.title_status) fe.title_status = 'Choose owned, financed or leased.';
  if (v.title_status && v.title_status !== 'owned_outright' && !String(v.finance_party_name ?? '').trim()) fe.finance_party_name = 'Enter the lender or lease company.';
  const files: Array<[string, { bytes: Uint8Array; type: string; ext: string }]> = [];
  for (const k of DOCS) {
    const f = await fileOf(form, `doc_${k}`);
    if (typeof f === 'string') fe[`doc_${k}`] = f; else if (f) files.push([k, f]);
  }
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const { user, aal } = await me();
    const roles = await rolesOf(user.id);
    const call = roles.admin ? 'ops_do' : 'va_do';
    const r = await door<{ application_id: string; application_number: string; owner_id: string; vehicle_id: string; approved: boolean;
      approve: { setup: { needed: boolean; owner_id: string; has_account: boolean; email: string | null; name: string } | null } | null }>(user.id, call, 'staff_add_owner_car', p, aal);
    let docs = 0;
    if (files.length) {
      const { storage } = await import('@/integrations/storage');
      const s = await storage();
      for (const [kind, f] of files) {
        const key = `owners/${r.owner_id}/vehicles/${r.vehicle_id}/${kind}-${crypto.randomUUID()}.${f.ext}`;
        await s.put('documents', key, f.bytes, f.type);
        await door(user.id, call, 'staff_vehicle_document', { vehicle_id: r.vehicle_id, kind, path: key, sha256: await sha256Hex(f.bytes), mime: f.type }, aal);
        docs++;
      }
    }
    let note: string | null = null;
    if (r.approved && r.approve?.setup?.needed) note = await setupEmail(user.id, aal, r.application_id, r.approve.setup).catch((e) => `The set-up email did not go: ${(fail(e) as { message: string }).message}`);
    again(['/admin/applications', '/admin/owners', `/admin/owners/${r.owner_id}`, '/admin', '/admin/invoices']);
    return { ok: true, data: { application_id: r.application_id, application_number: r.application_number, owner_id: r.owner_id, vehicle_id: r.vehicle_id, approved: r.approved, note, docs } };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- the owner portal: review, correct, sign an updated schedule
export async function ownerCorrect(p: { owner?: J; cars?: J[] }) {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const r = await rpc('server_owner_review_correct', { p_by: user.id, p: p as never }, SR);
    revalidatePath('/owner/review'); revalidatePath('/owner');
    return { ok: true as const, data: r as unknown as { changes: number } };
  } catch (e) { return fail(e); }
}
export async function signScheduleChange(changeId: string, name: string, agree: boolean, sha256: string) {
  const fe: Record<string, string> = {};
  if (name.trim().length < 2) fe.name = 'Type your full legal name.';
  if (!agree) fe.agree = 'Tick the box to confirm.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const r = await rpc('server_schedule_change_sign', { p_by: user.id, p: { change_id: changeId, name: name.trim(), agree, sha256 } }, SR);
    revalidatePath('/owner'); revalidatePath(`/owner/sign/schedule/${changeId}`);
    return { ok: true as const, data: r as unknown as { schedule_number: string } };
  } catch (e) { return fail(e); }
}
