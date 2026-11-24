'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { bookingPath } from '@/features/portal/status';
import { findBooking, requireUser } from '@/server/portal/data';
import { sha256Hex } from '@/server/links';
import { MAX_ETRANSFER_CENTS, MAX_PROOF_BYTES, cents, proofKind } from '@/features/money/etransfer';

// Hotfix 3650: the renter says they sent an e-Transfer, with the screenshot (Sign and pay, the booking page). The same
// Check e-Transfer item as Sales (3610): nothing is recorded until Finance or an Admin confirms it in one tap. The
// database checks the booking is the renter's, what is owed and the proof's path again.
type R<T = unknown> = ActionResult<T>;
const SR = { role: 'service_role' as const };
const fail = (message: string, code = 'refused'): R<never> => ({ ok: false, code, message });
const invalid = (fieldErrors: Record<string, string>, message = 'Check the highlighted fields.'): R<never> => ({ ok: false, code: 'invalid', message, fieldErrors });

export async function renterReportEtransfer(form: FormData): Promise<R<{ report_number: string }>> {
  const number = String(form.get('booking_number') ?? '');
  const amount = cents(String(form.get('amount') ?? ''));
  const covers = String(form.get('covers') ?? '');
  const sender = String(form.get('sender_name') ?? '').trim().slice(0, 120);
  const fe: Record<string, string> = {};
  if (amount === null || amount <= 0 || amount > MAX_ETRANSFER_CENTS) fe.amount = 'Enter the amount you sent.';
  if (!['rental', 'deposit', 'both'].includes(covers)) fe.covers = 'Choose what it pays.';
  const file = form.get('proof');
  if (!(file instanceof File) || file.size === 0) fe.proof = 'Add the screenshot of your e-Transfer.';
  else if (file.size > MAX_PROOF_BYTES) fe.proof = 'The screenshot must be under 10 MB.';
  if (Object.keys(fe).length) return invalid(fe);
  try {
    const user = await requireUser(bookingPath(number));
    const b = await findBooking(user, number);
    if (!b) return fail('Booking not found.');
    const bytes = new Uint8Array(await (file as File).arrayBuffer());
    const kind = proofKind(bytes);
    if (!kind) return invalid({ proof: 'Add a screenshot (JPG or PNG) or a PDF.' });
    const key = `etransfer/${b.id}/${crypto.randomUUID()}.${kind.ext}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('documents', key, bytes, kind.mime);
    try {
      const r = (await rpc('server_renter_etransfer_report', { p_user: user.id, p: { booking: b.id, amount_cents: amount, covers, sender_name: sender || null,
        proof: { path: key, sha256: await sha256Hex(bytes), mime: kind.mime } } }, SR)) as unknown as { report_number: string };
      revalidatePath(bookingPath(b.booking_number)); revalidatePath(bookingPath(b.booking_number, 'checkout')); revalidatePath('/account');
      return { ok: true, data: { report_number: r.report_number } };
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
  } catch (e) { return fail(e instanceof DbError ? e.message : 'Something went wrong. Please try again or call us.'); }
}
