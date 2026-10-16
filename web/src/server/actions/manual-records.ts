'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { sha256Hex } from '@/server/links';

// Payments received outside the processor, signatures on paper and documents sent to sign (migration 0044), for
// Admins and staff, through the staff door; the database decides who may do what (Admins; Finance within its single
// limit for payments; customer service for rental documents signed on paper) and checks everything again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const invalid = (fieldErrors: Record<string, string>, message = 'Check the highlighted fields.'): R<never> => ({ ok: false, code: 'invalid', message, fieldErrors });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const refresh = (paths: string[]) => { for (const p of paths) if (p.startsWith('/')) revalidatePath(p); };
const MAX = 15_000_000;
const cents = (v: string) => Math.round(Number(String(v).replace(/[$,\s]/g, '')) * 100);

/** A file from the form: a PDF, JPEG or PNG under 15 MB, checked by its first bytes. */
async function fileFrom(form: FormData, name: string, required: boolean): Promise<{ bytes: Uint8Array; type: string; ext: string } | null | string> {
  const file = form.get(name);
  if (!(file instanceof File) || file.size === 0) return required ? 'Choose the file.' : null;
  if (file.size > MAX) return 'The file must be under 15 MB.';
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50;
  if (!pdf && !jpg && !png) return 'Use a PDF, JPEG or PNG file.';
  return { bytes, type: pdf ? 'application/pdf' : jpg ? 'image/jpeg' : 'image/png', ext: pdf ? 'pdf' : jpg ? 'jpg' : 'png' };
}

// ---------------------------------------------------------------- payments received another way
const METHODS = ['e_transfer', 'cheque', 'cash', 'bank_transfer', 'other'];
export async function recordManualPayment(form: FormData): Promise<R<{ invoice_status: string | null; balance_cents: number | null; repeat: boolean }>> {
  const method = String(form.get('method') ?? '');
  const reference = String(form.get('reference') ?? '').trim();
  const receivedOn = String(form.get('received_on') ?? '');
  const amountRaw = String(form.get('amount') ?? '').trim();
  const note = String(form.get('note') ?? '').trim();
  const fe: Record<string, string> = {};
  if (!METHODS.includes(method)) fe.method = 'Choose how it was paid.';
  if (['e_transfer', 'cheque', 'bank_transfer'].includes(method) && reference.length < 3) fe.reference = method === 'cheque' ? 'Enter the cheque number.' : 'Enter the reference number.';
  if (method === 'other' && !note) fe.note = 'Say how it was paid.';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(receivedOn)) fe.received_on = 'Enter the date it was received.';
  const amount = amountRaw ? cents(amountRaw) : null;
  if (amount !== null && (!Number.isFinite(amount) || amount <= 0)) fe.amount = 'Enter the amount received, or leave it empty for the balance.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const { user, aal } = await me();
    const proof = await fileFrom(form, 'proof', false);
    if (typeof proof === 'string') return invalid({ proof: proof });
    let proofRef: Record<string, string> | undefined;
    if (proof) {
      const key = `payments/${new Date().getUTCFullYear()}/${crypto.randomUUID()}.${proof.ext}`;
      const { storage } = await import('@/integrations/storage');
      await (await storage()).put('documents', key, proof.bytes, proof.type);
      proofRef = { path: key, sha256: await sha256Hex(proof.bytes), mime: proof.type };
    }
    const invoice = String(form.get('invoice') ?? '') || null;
    const booking = String(form.get('booking') ?? '') || null;
    const r = await door<{ invoice_status: string | null; balance_cents: number | null; repeat?: boolean }>(user.id, 'ops_do', 'manual_payment_record', {
      invoice, booking, method, reference: reference || null, received_on: receivedOn, amount_cents: amount, note: note || null, proof: proofRef,
      purpose: String(form.get('purpose') ?? '') || null, settles_payment: String(form.get('settles_payment') ?? '') || null }, aal);
    refresh(String(form.get('refresh') ?? '').split(',').concat(['/admin/invoices', '/admin/owners', '/va/money', '/admin/reconciliation']));
    return { ok: true, data: { invoice_status: r.invoice_status ?? null, balance_cents: r.balance_cents ?? null, repeat: !!r.repeat } };
  } catch (e) { return fail(e); }
}

export async function voidManualPayment(id: string, reason: string, paths: string[] = []): Promise<R<null>> {
  if (!reason?.trim()) return invalid({ reason: 'Give the reason.' });
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'manual_payment_void', { id, reason: reason.trim() }, aal);
    refresh([...paths, '/admin/invoices', '/admin/owners', '/va/money']);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- signatures on paper
export async function recordPaperSignature(form: FormData): Promise<R<{ id: string }>> {
  const docType = String(form.get('doc_type') ?? '');
  const target = String(form.get('target_id') ?? '');
  const signer = String(form.get('signer_name') ?? '').trim();
  const signedOn = String(form.get('signed_on') ?? '');
  const fe: Record<string, string> = {};
  if (!docType || !target) fe.doc_type = 'Choose the document.';
  if (signer.length < 2) fe.signer_name = 'Enter the name of the person who signed.';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(signedOn)) fe.signed_on = 'Enter the date it was signed.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const { user, aal } = await me();
    const scan = await fileFrom(form, 'scan', true);
    if (typeof scan === 'string' || !scan) return invalid({ scan: typeof scan === 'string' ? scan : 'Upload the scan.' });
    // a rental agreement signed on paper: it is opened first when the renter never opened it (the document they signed)
    if (docType === 'rental_agreement') {
      const live = await rpc('server_signing_record', { p_booking: target }, { role: 'service_role' }).catch(() => null);
      if (!live) {
        const { openAgreement } = await import('@/server/portal/agreement');
        await openAgreement(target, user.id).catch(() => undefined);
      }
    }
    const key = `paper/${docType}/${new Date().getUTCFullYear()}/${crypto.randomUUID()}.${scan.ext}`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('agreements', key, scan.bytes, scan.type);
    const investment = docType === 'investment_agreement' ? { exemption_category: String(form.get('exemption_category') ?? '') || undefined,
      legal_advice_choice: String(form.get('legal_advice_choice') ?? '') || undefined, legal_adviser: String(form.get('legal_adviser') ?? '') || undefined } : undefined;
    const r = await door<{ id: string }>(user.id, 'ops_do', 'paper_signature_record', {
      doc_type: docType, target_id: target, signer_name: signer, signed_on: signedOn,
      witness_1_name: String(form.get('witness_1_name') ?? '').trim() || null, witness_2_name: String(form.get('witness_2_name') ?? '').trim() || null,
      note: String(form.get('note') ?? '').trim() || null, scan: { path: key, sha256: await sha256Hex(scan.bytes), mime: scan.type }, investment }, aal);
    refresh(String(form.get('refresh') ?? '').split(',').concat(['/admin/owners']));
    return { ok: true, data: { id: r.id } };
  } catch (e) { return fail(e); }
}

export async function voidPaperSignature(id: string, reason: string, paths: string[] = []): Promise<R<null>> {
  if (!reason?.trim()) return invalid({ reason: 'Give the reason.' });
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'paper_signature_void', { id, reason: reason.trim() }, aal);
    refresh([...paths, '/admin/owners']);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- documents sent to sign (investors, staff)
export async function createSignRequest(form: FormData): Promise<R<{ id: string }>> {
  const docType = String(form.get('doc_type') ?? '');
  if (!['investment_agreement', 'staff_agreement'].includes(docType)) return invalid({ doc_type: 'Choose the document.' });
  try {
    const { user, aal } = await me();
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0) return invalid({ file: 'Choose the PDF to sign.' });
    if (file.size > MAX) return invalid({ file: 'The PDF must be under 15 MB.' });
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) return invalid({ file: 'That file is not a PDF.' });
    const who = docType === 'investment_agreement' ? String(form.get('investor_id') ?? '') : String(form.get('staff_user_id') ?? '');
    const sha = await sha256Hex(bytes);
    const key = `${docType === 'investment_agreement' ? 'investors' : 'staff'}/${who}/to-sign/${sha.slice(0, 16)}.pdf`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('agreements', key, bytes, 'application/pdf');
    const r = await door<{ id: string }>(user.id, 'ops_do', 'sign_request_create', {
      doc_type: docType, investor_id: docType === 'investment_agreement' ? who : null, staff_user_id: docType === 'staff_agreement' ? who : null,
      title: String(form.get('title') ?? '').trim() || null, document: { path: key, sha256: sha },
      exemption_category: String(form.get('exemption_category') ?? '') || null, exemption_paragraph: String(form.get('exemption_paragraph') ?? '').trim() || null }, aal);
    refresh(String(form.get('refresh') ?? '').split(','));
    return { ok: true, data: { id: r.id } };
  } catch (e) { return fail(e); }
}

export async function voidSignRequest(id: string, reason: string, paths: string[] = []): Promise<R<null>> {
  if (!reason?.trim()) return invalid({ reason: 'Give the reason.' });
  try {
    const { user, aal } = await me();
    await door(user.id, 'ops_do', 'sign_request_void', { id, reason: reason.trim() }, aal);
    refresh(paths);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

/** The owner's on-screen Form A or B: rendered, stored and opened for signature (the same document returns the open request). */
export async function openOwnerFormAB(code: 'A' | 'B'): Promise<R<{ id: string; sha: string }>> {
  try {
    const { requireOwnerUser } = await import('@/server/owner/data');
    const user = await requireOwnerUser();
    const { openFormAB } = await import('@/server/sign-requests');
    return { ok: true, data: await openFormAB(user.id, code) };
  } catch (e) { return fail(e); }
}

export interface SignInput { id: string; sha: string; typedName?: string; drawn?: string; legalAdvice?: 'obtained' | 'declined'; adviser?: string; initials?: string; consent: string }
/** The person signs a document sent to them (Forms A and B, investment and staff agreements) in their portal. */
export async function signRequest(input: SignInput): Promise<R<{ status: string }>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const { signDocument } = await import('@/server/sign-requests');
    const r = await signDocument(user.id, input);
    for (const p of ['/owner/documents', '/owner', '/investor/sign', '/investor', '/va/sign', '/field/sign']) revalidatePath(p);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}
