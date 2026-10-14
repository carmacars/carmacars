import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';
import type { DebitTerms, OwnerInvoice } from '@/features/owner/types';

// Paying an owner invoice (owner billing specification sections 1 and 4): the upfront invoice
// (Install Fee and first and last month's Insurance Fee) and the monthly fee invoices. Card or
// Canadian pre-authorized debit (Stripe acss_debit with its mandate). Unlike a booking there is no
// hold: the charge is captured at once. The browser confirms in Stripe's own form; the server then
// fetches the PaymentIntent again and records what Stripe says (public.server_record_owner_invoice_payment),
// and the webhook does the same for the debit that settles days later. The database makes every
// second call a replay. The method is saved for the monthly debit on the 15th.
const SR = { role: 'service_role' as const };

export interface InvoiceFacts extends OwnerInvoice {
  customer_id: string | null;
  saved: Array<{ kind: string; brand_or_bank: string | null; last4: string | null; customer_id: string | null; method_id: string | null; mandate_id: string | null }>;
}

export async function invoiceIdFor(number: string): Promise<string | null> {
  return (await rpc('server_owner_invoice_id', { p_number: number }, SR)) as unknown as string | null;
}
export async function invoiceFacts(invoiceId: string, by: string): Promise<InvoiceFacts> {
  return (await rpc('server_owner_invoice_payment_facts', { p_invoice: invoiceId, p_by: by }, SR)) as unknown as InvoiceFacts;
}

export interface StartedInvoicePayment { provider: 'stripe' | 'fake'; intentId: string; clientSecret: string; amountCents: number; method: 'card' | 'acss_debit'; publishableKey: string | null; ownerName: string; ownerEmail: string }

/** One PaymentIntent per invoice, method, amount and attempt (the idempotency key), so a reload reuses it. */
export async function invoiceIntent(f: InvoiceFacts, method: 'card' | 'acss_debit', ownerType: 'individual' | 'corporation'): Promise<Intent> {
  const p = await payments();
  const customerId = f.customer_id ?? f.saved.find((s) => s.customer_id)?.customer_id
    ?? (await p.createCustomer({ email: f.owner_email ?? '', name: f.owner_name, ownerId: f.owner_id, idempotencyKey: `owner-customer:${f.owner_id}` })).id;
  const attempt = f.payments.filter((x) => x.status === 'failed').length;
  const terms = (await debitTerms());
  return p.createInvoiceIntent({
    invoiceId: f.id, invoiceNumber: f.invoice_number, ownerId: f.owner_id, amountCents: f.balance_cents, customerId, method,
    transactionType: ownerType === 'corporation' ? 'business' : 'personal', intervalDescription: terms.interval_description,
    description: `CarmaCars invoice ${f.invoice_number}, ${f.vehicle_name}`,
    idempotencyKey: `owner-invoice:${f.id}:${method}:${f.balance_cents}:${attempt}`
  });
}

export const publishableKey = () => env().NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null;

/** The debit agreement's schedule from Program settings (app.owner_debit_terms). */
export async function debitTerms(): Promise<DebitTerms> {
  return (await rpc('server_owner_debit_terms', {}, SR)) as unknown as DebitTerms;
}

// ---------------------------------------------------------------- the automatic monthly debit (migration 0037)
/** Records what Stripe says about a PaymentIntent of the automatic debit (the webhook; the Edge Function polls too). */
export async function settleDebitIntent(intentId: string): Promise<unknown> {
  const i = await (await payments()).retrieveIntent(intentId);
  return rpc('server_owner_debit_result', { p_intent: intentId, p: {
    intent_id: i.id, attempt_id: i.metadata.debit_attempt_id ?? null, status: i.status, charge_id: i.chargeId, mandate_id: i.mandateId,
    bank: i.bank ? { name: i.bank.name, last4: i.bank.last4 } : null, error_code: null, error_message: i.lastError
  } as never }, SR);
}

export interface StartedDebitSetup { provider: 'stripe' | 'fake'; setupId: string; clientSecret: string; publishableKey: string | null; ownerName: string; ownerEmail: string }
interface SetupFacts { owner_id: string; owner_type: 'individual' | 'corporation'; name: string; email: string | null; customer_id: string | null; terms: DebitTerms }

/** Banking > Set up pre-authorized debit: a SetupIntent for the owner's customer (made once). */
export async function startDebitSetup(userId: string): Promise<StartedDebitSetup> {
  const f = (await rpc('server_owner_debit_setup_facts', { p_by: userId }, SR)) as unknown as SetupFacts | null;
  if (!f) throw new Error('This account is not an owner account.');
  const p = await payments();
  const customerId = f.customer_id ?? (await p.createCustomer({ email: f.email ?? '', name: f.name, ownerId: f.owner_id, idempotencyKey: `owner-customer:${f.owner_id}` })).id;
  const s = await p.createDebitSetup({ ownerId: f.owner_id, customerId, transactionType: f.owner_type === 'corporation' ? 'business' : 'personal',
    intervalDescription: f.terms.interval_description, idempotencyKey: `owner-debit-setup:${f.owner_id}:${new Date().toISOString().slice(0, 13)}` });
  return { provider: p.name, setupId: s.id, clientSecret: s.clientSecret ?? '', publishableKey: publishableKey(), ownerName: f.name, ownerEmail: f.email ?? '' };
}

/** After Stripe's form: the SetupIntent is read again from Stripe and the method saved (pending until verified). */
export async function finishDebitSetup(userId: string, setupId: string): Promise<{ ok: boolean; active: boolean; message?: string }> {
  const f = (await rpc('server_owner_debit_setup_facts', { p_by: userId }, SR)) as unknown as SetupFacts | null;
  const s = await (await payments()).retrieveDebitSetup(setupId);
  if (!f || s.metadata.owner_id !== f.owner_id) return { ok: false, active: false, message: 'This bank setup is not yours.' };
  if (!['succeeded', 'processing', 'requires_action'].includes(s.status) || !s.paymentMethodId || !s.mandateId) {
    return { ok: false, active: false, message: s.lastError ?? 'The bank setup did not finish. Nothing was saved.' };
  }
  const r = (await rpc('server_owner_record_debit_setup', { p_by: userId, p: { status: s.status, customer_id: s.customerId, method_id: s.paymentMethodId,
    mandate_id: s.mandateId, bank: s.bank } as never }, SR)) as unknown as { ok: boolean; active: boolean };
  return { ok: true, active: r.active };
}

/** setup_intent.succeeded (micro-deposits verified later): the pending method becomes the debit method. */
export async function verifyDebitSetup(setupId: string): Promise<unknown> {
  const s = await (await payments()).retrieveDebitSetup(setupId);
  if (s.status !== 'succeeded' || !s.paymentMethodId) return { ignored: s.status };
  return rpc('server_owner_debit_setup_verified', { p_method: s.paymentMethodId, p_mandate: s.mandateId ?? '' }, SR);
}

export type InvoiceSettle = { ok: true; status: 'succeeded' | 'pending' | 'failed'; invoiceStatus: string; message?: string } | { ok: false; reason: string; message: string };

/** Records what the processor says about one PaymentIntent of an owner invoice. */
export async function settleInvoiceIntent(intentId: string, by: string | null, opts: { failedEvent?: boolean } = {}): Promise<InvoiceSettle> {
  const p = await payments();
  const i = await p.retrieveIntent(intentId);
  const invoiceId = i.metadata.owner_invoice_id;
  if (!invoiceId || i.metadata.purpose !== 'owner_invoice') return { ok: false, reason: 'not_an_invoice_payment', message: 'This payment is not for an owner invoice.' };
  if (i.currency !== 'cad') return { ok: false, reason: 'currency', message: 'Owner invoices are paid in Canadian dollars.' };
  let status: 'succeeded' | 'pending' | 'failed';
  if (i.status === 'succeeded') status = 'succeeded';
  else if (i.status === 'processing') status = 'pending';
  else if (i.status === 'canceled' || (opts.failedEvent && i.status === 'requires_payment_method')) status = 'failed';
  else return { ok: false, reason: 'not_confirmed', message: i.lastError ?? 'The payment was not completed. Nothing was charged.' };
  const r = (await rpc('server_record_owner_invoice_payment', {
    p_invoice: invoiceId,
    p: {
      status, method: i.methodType === 'acss_debit' ? 'pre_authorized_debit' : 'card', amount_cents: i.amountCents, currency: i.currency,
      processor: { processor: 'stripe', payment_id: i.id, charge_id: i.chargeId, customer_id: i.customerId, method_id: i.paymentMethodId, mandate_id: i.mandateId },
      card: i.card ? { brand: i.card.brand, last4: i.card.last4 } : null,
      bank: i.bank ? { name: i.bank.name, last4: i.bank.last4 } : null,
      failure_message: status === 'failed' ? (i.lastError ?? 'The payment did not go through.') : null,
      save_method: true
    },
    p_by: by ?? undefined
  }, SR)) as unknown as { ok: boolean; status: string; invoice_status: string };
  return { ok: true, status, invoiceStatus: r.invoice_status, message: status === 'failed' ? (i.lastError ?? undefined) : undefined };
}
