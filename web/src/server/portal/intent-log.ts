import 'server-only';
import { rpc } from '@/lib/db/repo';

// Each card form opened is on record (migration 0079, payment_intents_opened): the PaymentIntent made for it, before
// anything is paid. Never in the way of a payment: a failure to write it is only logged.
export async function intentOpened(p: { payment_id: string; purpose: string; booking_id?: string | null; owner_invoice_id?: string | null; amount_cents: number; by?: string | null }): Promise<void> {
  try {
    await rpc('server_payment_intent_opened', { p: { processor: 'stripe', ...p } as never }, { role: 'service_role' });
  } catch (e) { console.error('payment intent log', e instanceof Error ? e.message : e); }
}
