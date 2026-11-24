'use server';
import { revalidatePath } from 'next/cache';
import { cookies } from 'next/headers';
import type { ActionResult } from '@/features/forms/schemas';
import { refusalMessage } from '@/lib/db/refusal';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal, VA_FN_COOKIE } from '@/server/door';
import { sha256Hex } from '@/server/links';
import { COVERS, MAX_ETRANSFER_CENTS, MAX_PROOF_BYTES, cents, proofKind } from '@/features/money/etransfer';

// Release 49 (3610): Sales reports an e-Transfer a renter sent (with the screenshot), Finance or an Admin confirms it or
// sends it back. Through the staff door (ops calls); the database decides who may do each and records nothing for Sales:
// only Confirm received records the payment, by the same path as Record a payment.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: refusalMessage(e) });
const invalid = (fieldErrors: Record<string, string>, message = 'Check the highlighted fields.'): R<never> => ({ ok: false, code: 'invalid', message, fieldErrors });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  let va: string | null = null;
  try { va = (await cookies()).get(VA_FN_COOKIE)?.value ?? null; } catch { va = null; }
  return { user, aal: await sessionAal(), va };
}
const withFn = (p: Record<string, unknown>, va: string | null) => (va ? { ...p, _va: va } : p);
const refresh = (number: string) => {
  for (const base of ['/admin/bookings', '/staff/bookings']) { revalidatePath(base); revalidatePath(`${base}/${encodeURIComponent(number)}`); }
  revalidatePath('/admin'); revalidatePath('/staff');
};

/** Renter sent an e-Transfer: the amount, what it covers, the sender (optional) and the proof (required). */
export async function reportEtransfer(form: FormData): Promise<R<{ report_number: string }>> {
  const booking = String(form.get('booking') ?? '');
  const number = String(form.get('booking_number') ?? '');
  const amount = cents(String(form.get('amount') ?? ''));
  const covers = String(form.get('covers') ?? '');
  const sender = String(form.get('sender_name') ?? '').trim().slice(0, 120);
  const fe: Record<string, string> = {};
  if (!/^[0-9a-f-]{36}$/.test(booking)) return fail(new Error('Open the booking again.'));
  if (amount === null || amount <= 0 || amount > MAX_ETRANSFER_CENTS) fe.amount = 'Enter the amount the renter sent.';
  if (!COVERS.some(([c]) => c === covers)) fe.covers = 'Choose what it covers.';
  const file = form.get('proof');
  if (!(file instanceof File) || file.size === 0) fe.proof = 'Add the screenshot or proof of the e-Transfer.';
  else if (file.size > MAX_PROOF_BYTES) fe.proof = 'The proof must be under 10 MB.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const { user, aal, va } = await me();
    const bytes = new Uint8Array(await (file as File).arrayBuffer());
    const kind = proofKind(bytes);
    if (!kind) return invalid({ proof: 'Add a screenshot (JPG or PNG) or a PDF.' });
    const key = `etransfer/${booking}/${crypto.randomUUID()}.${kind.ext}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('documents', key, bytes, kind.mime);
    try {
      const r = await door<{ report_number: string }>(user.id, 'ops_do', 'etransfer_report', withFn({ booking, amount_cents: amount, covers,
        sender_name: sender || null, proof: { path: key, sha256: await sha256Hex(bytes), mime: kind.mime } }, va), aal);
      if (number) refresh(number);
      return { ok: true, data: { report_number: r.report_number } };
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
  } catch (e) { return fail(e); }
}

/** Check e-Transfer: Confirm received (records the payment) or Not received (back to the rep with the reason). */
export async function decideEtransfer(p: { id: string; booking_number: string; decision: 'confirm' | 'decline'; reason?: string; reference?: string }): Promise<R<{ status: string; booking_status?: string }>> {
  if (!/^[0-9a-f-]{36}$/.test(p.id)) return fail(new Error('Open the booking again.'));
  if (p.decision === 'decline' && (p.reason ?? '').trim().length < 5) return invalid({ reason: 'Say why it was not received (5 characters or more): the rep sees it.' });
  if (p.reference && p.reference.trim().length > 0 && p.reference.trim().length < 3) return invalid({ reference: 'Enter the bank reference (3 characters or more), or leave it empty.' });
  try {
    const { user, aal, va } = await me();
    const r = await door<{ status: string; booking_status?: string }>(user.id, 'ops_do', 'etransfer_decide', withFn({ id: p.id, decision: p.decision,
      reason: p.reason?.trim() || null, reference: p.reference?.trim() || null }, va), aal);
    refresh(p.booking_number);
    return { ok: true, data: { status: r.status, booking_status: r.booking_status } };
  } catch (e) { return fail(e); }
}
