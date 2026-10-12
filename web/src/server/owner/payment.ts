import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';
import type { OwnerInvoice } from '@/features/owner/types';

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
  return p.createInvoiceIntent({
    invoiceId: f.id, invoiceNumber: f.invoice_number, ownerId: f.owner_id, amountCents: f.balance_cents, customerId, method,
    transactionType: ownerType === 'corporation' ? 'business' : 'personal',
    description: `CarmaCars invoice ${f.invoice_number}, ${f.vehicle_name}`,
    idempotencyKey: `owner-invoice:${f.id}:${method}:${f.balance_cents}:${attempt}`
  });
}

export const publishableKey = () => env().NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null;

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
