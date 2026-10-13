'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { payments } from '@/integrations/payments';

// The money screens of migration 0032 (through the door's ops calls): issue an approved refund through the
// payments module, the guided Deposit settlement, a notice on a toll, the insurer invoice email. The
// database checks the person (Finance or an Admin) and the rule; its refusal is shown as written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

interface Begin { already?: boolean; refund_id: string; amount_cents: number; payment_intent: string | null; charge: string | null; idempotency_key: string; booking_id: string; status?: string }

/** Issue an approved refund: the database marks it processing and gives the key; the processor refunds
 *  once whatever happens (the same key every time); the result is recorded. */
async function issueRefund(userId: string, aal: 'aal1' | 'aal2' | null, id: string): Promise<{ status: string; already?: boolean }> {
  const b = await door<Begin>(userId, 'ops_do', 'refund_issue_begin', { id }, aal);
  if (b.already) return { status: 'paid', already: true };
  try {
    const r = await (await payments()).refund({ paymentIntentId: b.payment_intent, chargeId: b.charge, amountCents: b.amount_cents, idempotencyKey: b.idempotency_key,
      metadata: { refund_id: b.refund_id, booking_id: b.booking_id } });
    const ok = r.status === 'succeeded' || r.status === 'pending' || r.status === 'requires_action';
    const done = await door<{ status: string }>(userId, 'ops_do', 'refund_issue_finish', { id, ok, status: ok ? (r.status === 'succeeded' ? 'succeeded' : 'pending') : 'failed',
      processor_refund_id: r.id, error: r.failureReason, raw: { id: r.id, status: r.status, amount: r.amountCents } }, aal);
    return { status: done.status };
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'The processor refused the refund';
    await door(userId, 'ops_do', 'refund_issue_finish', { id, ok: false, status: 'failed', error: msg.slice(0, 300) }, aal).catch(() => undefined);
    throw new Error(`The refund was not sent: ${msg}`);
  }
}

export async function opsAct<T = Record<string, unknown>>(action: string, p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    const data = action === 'refund_issue'
      ? (await issueRefund(user.id, aal, String(p.id ?? ''))) as unknown as T
      : await door<T>(user.id, 'ops_do', action, p, aal);
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function opsRead<T = Record<string, unknown>>(what: 'deposit_preview' | 'files' | 'listing_budget', p: Record<string, unknown> = {}): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<T>(user.id, 'ops_read', what, p, aal) };
  } catch (e) { return fail(e); }
}
