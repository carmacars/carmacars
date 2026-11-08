import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';
import { siteUrl } from '@/lib/site';
import { newPayToken, payTokenHash } from '@/server/pay-token';
import { outcomeOf, settlementOrder, stepFor, type MoneyFacts, type MoneyOutcome } from '@/server/money-steps';
import { autoHoldStep } from '@/server/deposit-auto';
import { settlePayreq } from '@/server/paylink';
import { plainProcessorError } from '@/features/money/charge-reasons';

// The deposit guard's runner (migration 0155). The database decides every money step and marks it on a payment
// (payments.server_action); this runs it at Stripe once (the idempotency key is the payment's) and records the answer.
// Nothing here decides to release a deposit: a release or refund exists only because a person pressed Settle (or an
// Admin acted). The capture before a hold lapses keeps the money; the settlement refunds what is not owed.
const SR = { role: 'service_role' as const };
type Call = (fn: string, args: Record<string, unknown>) => Promise<unknown>;
const call: Call = (fn, args) => rpc(fn as never, args as never, SR) as Promise<unknown>;

interface Finish { ok: boolean; next?: { payment_id?: string; balance?: boolean; next?: MoneyFacts | null } | MoneyFacts | null }

/** One marked payment: the Stripe call, then the database records the answer (and says what comes next). */
export async function runMoneyAction(paymentId: string, depth = 0): Promise<{ ok: boolean; action?: string; error?: string }> {
  const f = (await call('server_money_action', { p_payment: paymentId })) as MoneyFacts | null;
  if (!f || f.status !== 'pending') return { ok: true };
  const step = stepFor(f);
  let out: MoneyOutcome;
  try {
    const p = await payments();
    switch (step.call) {
      case 'none': out = outcomeOf(step, {}); break;
      case 'skip': out = { ok: true }; break;
      case 'capture': {
        try { out = outcomeOf(step, await p.captureIntent(step.intentId, step.key, step.amountCents)); }
        catch (e) {
          // a lapsed hold cannot be captured: Stripe says canceled
          const st = await p.retrieveIntent(step.intentId).then((i) => i.status).catch(() => null);
          out = { ok: false, intent_status: st, error: e instanceof Error ? e.message : 'Stripe refused the capture' };
        }
        break;
      }
      case 'cancel': {
        try { out = outcomeOf(step, await p.cancelIntent(step.intentId, step.key)); }
        catch (e) {
          // already canceled (it lapsed, or a capture ended it): the hold is gone, which is what a release wants
          const st = await p.retrieveIntent(step.intentId).then((i) => i.status).catch(() => null);
          out = st === 'canceled' || st === 'succeeded' ? { ok: true, intent_status: st } : { ok: false, intent_status: st, error: e instanceof Error ? e.message : 'Stripe refused' };
        }
        break;
      }
      case 'refund': out = outcomeOf(step, await p.refund({ paymentIntentId: step.intentId, chargeId: step.chargeId, amountCents: step.amountCents, idempotencyKey: step.key, metadata: step.metadata })); break;
      case 'charge': out = outcomeOf(step, await p.chargeOffSession({ customerId: step.customerId, paymentMethodId: step.methodId, amountCents: step.amountCents, description: step.description, metadata: step.metadata, idempotencyKey: step.key })); break;
    }
  } catch (e) {
    out = { ok: false, error: e instanceof Error ? e.message : 'Stripe could not be reached' };
  }
  const done = (await call('server_money_action_finish', { p_payment: paymentId, p: { ...out, error: out.error ? String(out.error).slice(0, 300) : null } })) as Finish;
  // what comes next: the deposit charged to the saved card after a lapse, or the balance followed up
  const nx = done?.next as { payment_id?: string; balance?: boolean; next?: MoneyFacts | null } | null | undefined;
  if (depth < 3 && nx) {
    const nextPay = nx.next?.payment_id ?? nx.payment_id;
    if (nextPay && nextPay !== paymentId) await runMoneyAction(nextPay, depth + 1);
    if (nx.balance) await collectBalance(f.booking_id, depth + 1);
  }
  return { ok: !!done?.ok, action: f.action, error: out.ok ? undefined : out.error ?? undefined };
}

/** The steps a settlement decided (app.settle_deposit's server_actions), captures first, then the balance. */
export async function runSettlement(bookingId: string, actions: Array<{ action: string; payment_id: string }> | null | undefined) {
  const results: Array<{ action: string; ok: boolean; error?: string }> = [];
  for (const a of settlementOrder(actions ?? [])) {
    const r = await runMoneyAction(a.payment_id).catch((e) => ({ ok: false, error: e instanceof Error ? e.message : String(e) }));
    results.push({ action: a.action, ok: r.ok, error: r.error });
  }
  const balance = await collectBalance(bookingId).catch(() => null);
  return { results, balance };
}

interface BalanceNext { action: 'none' | 'wait' | 'charge_card' | 'pay_link' | 'task' | 'review'; open_cents: number; payment?: MoneyFacts; booking_id?: string; booking_number?: string;
  renter?: { id: string; legal_name: string; email: string | null; customer_id: string | null } }

/** What is still owed after the deposit: the card on file, else a pay link by email and text, else a Finance task. */
export async function collectBalance(bookingId: string, depth = 0): Promise<{ action: string; open_cents: number }> {
  const n = (await call('server_balance_next', { p_booking: bookingId })) as BalanceNext | null;
  if (!n) return { action: 'none', open_cents: 0 };
  if (n.action === 'charge_card' && n.payment) {
    // declined: the database's answer brings the balance back here, and the next step is the pay link
    if (depth < 3) await runMoneyAction(n.payment.payment_id, depth + 1);
    return { action: 'charge_card', open_cents: n.open_cents };
  }
  if (n.action === 'pay_link' && n.renter) {
    const token = newPayToken();
    const q = (await call('server_balance_payreq', { p_booking: bookingId, p_token_sha256: await payTokenHash(token), p_amount: n.open_cents })) as { id: string; booking_number: string };
    const p = await payments();
    const customerId = n.renter.customer_id ?? (await p.createCustomer({ email: n.renter.email ?? '', name: n.renter.legal_name, renterId: n.renter.id, idempotencyKey: `customer:${n.renter.id}` })).id;
    const intent = await p.createStaffIntent({ amountCents: n.open_cents, customerId, capture: 'manual', description: `CarmaCars booking ${q.booking_number}: charges after the rental`,
      metadata: { booking_id: bookingId, booking_number: q.booking_number, purpose: 'staff_request', payment_request_id: q.id, covers: 'later' }, idempotencyKey: `payreq:${q.id}` });
    await call('server_payreq_attach', { p_id: q.id, p_intent: intent.id });
    await call('server_balance_payreq_send', { p_id: q.id, p_link: `${siteUrl()}/pay/${token}` });
    return { action: 'pay_link', open_cents: n.open_cents };
  }
  return { action: n.action, open_cents: n.open_cents };
}

interface Sweep { captures: Array<{ deposit_id: string; booking_number: string }>; payments: string[]; balances: string[] }

/** The deposit job (the Worker's cron tick when public.server_jobs_due says "deposits"): holds captured before they
 *  lapse, marked payments still waiting, balances followed up once a day. A bounded share per run. */
export async function runDepositGuard(limit = 40) {
  const s = (await call('server_deposit_guard_sweep', {})) as Sweep;
  const out = { captured: 0, capture_failed: 0, payments: 0, balances: 0, errors: [] as string[] };
  for (const c of (s.captures ?? []).slice(0, limit)) {
    try {
      const f = (await call('server_deposit_capture_begin', { p_deposit: c.deposit_id })) as MoneyFacts | null;
      if (!f) continue;
      const r = await runMoneyAction(f.payment_id);
      if (r.ok) out.captured++; else out.capture_failed++;
    } catch (e) { out.errors.push(`${c.booking_number}: ${e instanceof Error ? e.message : String(e)}`.slice(0, 200)); }
  }
  for (const id of (s.payments ?? []).slice(0, limit)) {
    try { await runMoneyAction(id); out.payments++; } catch (e) { out.errors.push((e instanceof Error ? e.message : String(e)).slice(0, 200)); }
  }
  for (const b of (s.balances ?? []).slice(0, limit)) {
    try { await collectBalance(b); out.balances++; } catch (e) { out.errors.push((e instanceof Error ? e.message : String(e)).slice(0, 200)); }
  }
  // 0261: the holds of the pickup day first; a try that fails makes its booking's link due at once, sent just below
  const holds = await placeDepositHolds().catch((e) => ({ held: 0, failed: 0, errors: [(e instanceof Error ? e.message : String(e)).slice(0, 200)] }));
  const links = await sendDepositLinks().catch((e) => ({ sent: 0, not_sent: 0, errors: [(e instanceof Error ? e.message : String(e)).slice(0, 200)] }));
  // r33 (0750): a hold about 24 hours from its expiry, re-authorized before it lapses (an alert when it cannot be)
  const reauth = await reauthorizeDueHolds().catch((e) => ({ renewed: 0, failed: 0, errors: [(e instanceof Error ? e.message : String(e)).slice(0, 200)] }));
  return { ...out, deposit_holds: holds.held, deposit_holds_failed: holds.failed, deposit_links: links.sent, deposit_links_not_sent: links.not_sent,
    holds_reauthorized: reauth.renewed, holds_reauth_failed: reauth.failed,
    errors: [...out.errors, ...holds.errors, ...links.errors, ...reauth.errors] };
}

/** 0261: the deposit hold on the morning of the pickup day (Program settings, Deposit timing), off-session on the card on
 *  file: the database says which bookings are due and makes one request per booking (never two holds); Stripe authorizes
 *  (manual capture) and the hold is recorded as every hold (settlePayreq). A failure is recorded with its reason: a task
 *  "Deposit not taken", and the deposit link goes to the renter in the same run. */
export async function placeDepositHolds(limit = 10): Promise<{ held: number; failed: number; errors: string[] }> {
  const due = ((await call('server_deposit_autos_due', {})) as Array<{ booking_id: string; booking_number: string }> | null) ?? [];
  const out = { held: 0, failed: 0, errors: [] as string[] };
  // 0541: Program settings, Extended deposit holds (off until Stripe confirms IC+): asked if available, never required
  const extendedHold = due.length ? Boolean(await call('server_deposit_extended_holds', {}).catch(() => false)) : false;
  for (const d of due.slice(0, limit)) {
    try {
      // the request's token is never sent (no link): a fresh one, thrown away
      const b = (await call('server_deposit_auto_begin', { p_booking: d.booking_id, p_token_sha256: await payTokenHash(newPayToken()) })) as
        { ok: boolean; id?: string; reason?: string; booking_number?: string; amount_cents?: number; customer_id?: string; method_id?: string } | null;
      if (!b?.ok || !b.id) { if (b?.id) out.failed++; continue; }
      const p = await payments();
      let intent: Awaited<ReturnType<typeof p.chargeOffSession>> | null = null;
      let err: unknown = null;
      try {
        intent = await p.chargeOffSession({ customerId: b.customer_id ?? '', paymentMethodId: b.method_id ?? '', amountCents: b.amount_cents ?? 0, capture: 'manual', extendedHold,
          description: `CarmaCars booking ${b.booking_number ?? d.booking_number}: deposit hold`,
          metadata: { booking_id: d.booking_id, booking_number: b.booking_number ?? d.booking_number, purpose: 'staff_request', payment_request_id: b.id, covers: 'deposit' },
          idempotencyKey: `payreq:${b.id}` });
      } catch (e) { err = e; }
      if (intent) await call('server_payreq_attach', { p_id: b.id, p_intent: intent.id });
      const step = autoHoldStep(intent, err);
      if (step.next === 'settle' && intent) {
        const r = await settlePayreq(b.id, intent.id, 'hold', intent);
        if (r.ok) { out.held++; continue; }
        await call('server_deposit_auto_failed', { p_id: b.id, p_error: r.message ?? r.reason ?? 'the hold was not recorded' });
      } else if (step.next === 'failed') {
        if (step.cancel && intent) await p.cancelIntent(intent.id, `void:${intent.id}`).catch(() => undefined);
        await call('server_deposit_auto_failed', { p_id: b.id, p_error: step.reason });
      }
      out.failed++;
    } catch (e) { out.errors.push(`${d.booking_number}: ${e instanceof Error ? e.message : String(e)}`.slice(0, 200)); }
  }
  return out;
}

/** 0213: the deposit hold link texted before pickup (Site settings, Deposit link by text): the same payment request as
 *  Money > Collect a card > The deposit hold, its Stripe hold intent, then the text from the CarmaCars number. The database
 *  decides which bookings are due and keeps one live request per booking and deposit; a text not sent makes a task. */
export async function sendDepositLinks(limit = 20): Promise<{ sent: number; not_sent: number; errors: string[] }> {
  const due = ((await call('server_deposit_links_due', {})) as Array<{ booking_id: string; booking_number: string }> | null) ?? [];
  const out = { sent: 0, not_sent: 0, errors: [] as string[] };
  for (const d of due.slice(0, limit)) {
    try {
      const token = newPayToken();
      const q = (await call('server_deposit_link_payreq', { p_booking: d.booking_id, p_token_sha256: await payTokenHash(token) })) as
        { ok: boolean; id: string; booking_number: string; amount_cents: number; renter: { id: string; legal_name: string; email: string | null; customer_id: string | null } } | null;
      if (!q?.ok) continue;
      const p = await payments();
      const customerId = q.renter.customer_id ?? (await p.createCustomer({ email: q.renter.email ?? '', name: q.renter.legal_name, renterId: q.renter.id, idempotencyKey: `customer:${q.renter.id}` })).id;
      const intent = await p.createStaffIntent({ amountCents: q.amount_cents, customerId, capture: 'manual', description: `CarmaCars booking ${q.booking_number}: deposit hold`,
        metadata: { booking_id: d.booking_id, booking_number: q.booking_number, purpose: 'staff_request', payment_request_id: q.id, covers: 'deposit' }, idempotencyKey: `payreq:${q.id}` });
      await call('server_payreq_attach', { p_id: q.id, p_intent: intent.id });
      const r = (await call('server_deposit_link_send', { p_id: q.id, p_link: `${siteUrl()}/pay/${token}` })) as { ok: boolean } | null;
      if (r?.ok) out.sent++; else out.not_sent++;
    } catch (e) { out.errors.push(`${d.booking_number}: ${e instanceof Error ? e.message : String(e)}`.slice(0, 200)); }
  }
  return out;
}

/** r33 (0750): the deposit holds of bookings not settled, about 24 hours before they expire: a new hold on the saved card
 *  for what is still held (off-session, extended if Program settings allow), then the old hold released, exactly as Re-
 *  authorize the hold does for a person; run as the system. One try per hold every 6 hours; a failure is recorded on
 *  the booking in plain words and alerts Finance and an Admin (deposit_reauth_failed). */
export async function reauthorizeDueHolds(limit = 10): Promise<{ renewed: number; failed: number; errors: string[] }> {
  const due = ((await call('server_deposit_reauth_due', { p_limit: limit })) as Array<{ deposit_id: string; booking_number: string }> | null) ?? [];
  const out = { renewed: 0, failed: 0, errors: [] as string[] };
  for (const d of due) {
    try {
      const b = (await call('server_deposit_reauth_begin', { p_deposit: d.deposit_id })) as
        { ok: boolean; skip?: boolean; deposit_id: string; booking_id: string; booking_number: string; amount_cents: number; customer_id: string; method_id: string; old_intent: string | null; extended: boolean; idempotency_key: string } | null;
      if (!b?.ok) { if (b && !b.skip) out.failed++; continue; }
      const pay = await payments();
      let fin: Record<string, unknown> = { deposit: b.deposit_id, amount_cents: b.amount_cents, ok: false };
      try {
        const i = await pay.chargeOffSession({ customerId: b.customer_id, paymentMethodId: b.method_id, amountCents: b.amount_cents, capture: 'manual', extendedHold: b.extended,
          description: `CarmaCars booking ${b.booking_number}: deposit hold (re-authorized)`, metadata: { booking_id: b.booking_id, booking_number: b.booking_number, purpose: 'deposit_reauth', deposit_id: b.deposit_id },
          idempotencyKey: b.idempotency_key });
        if (i.status === 'requires_capture') fin = { ...fin, ok: true, intent_id: i.id, charge_id: i.chargeId, capture_before: i.captureBefore ?? null, extended: Boolean(i.extendedAuth) };
        else {
          if (i.status !== 'canceled') await pay.cancelIntent(i.id, `void:${i.id}`).catch(() => undefined);
          fin = { ...fin, error: plainProcessorError(i.lastError ?? `status ${i.status}`, 'hold') };
        }
      } catch (e) { fin = { ...fin, error: plainProcessorError(e instanceof Error ? e.message : null, 'hold') }; }
      const r = (await call('server_deposit_reauth_finish', { p: fin })) as { ok: boolean } | null;
      if (r?.ok) {
        out.renewed++;
        if (b.old_intent) await pay.cancelIntent(b.old_intent, `hold-reauth-release:${b.old_intent}`).catch(() => undefined);
      } else out.failed++;
    } catch (e) { out.errors.push(`${d.booking_number}: ${e instanceof Error ? e.message : String(e)}`.slice(0, 200)); }
  }
  return out;
}
