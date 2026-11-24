import 'server-only';
import { rpc } from '@/lib/db/repo';
import { settleIntent } from '@/server/portal/payment';
import { settleAddonIntent } from '@/server/portal/addon-payment';
import { settleDebitIntent, settleInvoiceIntent, verifyDebitSetup } from '@/server/owner/payment';
import { settlePayreq } from '@/server/paylink';
import { settleGiftIntent } from '@/server/gift-cards';
import { isHoldLapse } from '@/server/money-steps';
import { runMoneyAction } from '@/server/deposit-guard';

// What a processor's event about one payment does, by the payment's purpose (its metadata): the booking's payment, a pay
// link, a gift card, add-ons, an owner invoice or debit. Moved out of the Stripe webhook in r50 so the Helcim webhook
// (api/webhooks/helcim) settles its payments through exactly the same steps: each one reads the payment again from the
// processor (never the event body) and the database makes a second call a repeat.
const SR = { role: 'service_role' as const };

export async function settleIntentEvent(eventId: string, type: string, obj: { id?: string; object?: string; metadata?: Record<string, string> } & Record<string, unknown>): Promise<unknown> {
  let result: unknown = { ignored: type };
  if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'booking_total') {
    if (type === 'payment_intent.amount_capturable_updated' || type === 'payment_intent.succeeded') {
      // the PaymentIntent is fetched again from Stripe: the event body is never trusted for money
      result = await settleIntent(obj.id, null, eventId);
    } else if (type === 'payment_intent.payment_failed' || type === 'payment_intent.canceled') {
      result = { noted: type };
    }
  } else if ((obj.object === 'payment_intent' || obj.object === 'setup_intent') && obj.id && obj.metadata?.purpose === 'staff_request' && obj.metadata?.payment_request_id) {
    // a card payment, deposit hold or saved card staff started from a booking (0129), when the pay page did not finish
    if (['payment_intent.succeeded', 'payment_intent.amount_capturable_updated', 'setup_intent.succeeded'].includes(type)) {
      result = await settlePayreq(obj.metadata.payment_request_id, obj.id, obj.object === 'setup_intent' ? 'setup' : obj.metadata.covers === 'deposit' ? 'hold' : 'charge');
    } else if (isHoldLapse(type, obj as Record<string, unknown>)) {
      // a deposit hold lapsed at the bank (0155): recorded, and on a rental on the road or after it the deposit is
      // charged to the saved card (the database says so and gives the payment)
      const lapsed = (await rpc('server_deposit_hold_lapsed', { p_intent: obj.id }, SR)) as unknown as { next?: { payment_id?: string } | null };
      if (lapsed?.next?.payment_id) await runMoneyAction(lapsed.next.payment_id);
      result = lapsed;
    }
  } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'gift_card') {
    // a gift card bought on /gift-cards (3600), when the browser did not finish
    if (type === 'payment_intent.succeeded') result = await settleGiftIntent(obj.id);
  } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'addon_unpaid') {
    // add-ons paid on the booking's add-on pay page (0079), when the browser did not finish
    if (type === 'payment_intent.succeeded') result = await settleAddonIntent(obj.id, null);
  } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'owner_invoice' && obj.metadata?.debit_attempt_id) {
    // the automatic monthly debit (migration 0037): the attempt settles, fails (late fee, retry or arrears) or is canceled
    if (['payment_intent.succeeded', 'payment_intent.processing', 'payment_intent.payment_failed', 'payment_intent.canceled'].includes(type)) {
      result = await settleDebitIntent(obj.id);
    }
  } else if (obj.object === 'mandate' && obj.id && type === 'mandate.updated') {
    // a pre-authorized debit agreement cancelled at the bank or by Stripe
    if ((obj as { status?: string }).status === 'inactive') result = await rpc('server_owner_mandate_inactive', { p_mandate: obj.id }, SR);
  } else if (obj.object === 'setup_intent' && obj.id && obj.metadata?.purpose === 'owner_debit_setup') {
    if (type === 'setup_intent.succeeded') result = await verifyDebitSetup(obj.id);
  } else if (obj.object === 'payment_intent' && obj.id && obj.metadata?.purpose === 'owner_invoice') {
    // an owner invoice: a card charge, or a pre-authorized debit submitted (processing) and settled days later
    if (['payment_intent.succeeded', 'payment_intent.processing', 'payment_intent.payment_failed', 'payment_intent.canceled'].includes(type)) {
      result = await settleInvoiceIntent(obj.id, null, { failedEvent: type === 'payment_intent.payment_failed' || type === 'payment_intent.canceled' });
    }
  }
  return result;
}
