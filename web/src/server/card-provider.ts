import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { stripeReader } from '@/features/api-access/stripe-inspect';
import { cardOn, type CardPayments } from '@/features/money/card-pay';

// Hotfix 3650: the one seam between the site and the card processor. Card payments are on only when Program settings
// card_payments is on AND the processor takes charges (the database answers: app.card_payments_state, provider
// stripe | helcim | off). Every renter pay page and staff card tool asks here first; with cards off they show e-Transfer.
// The processor's account is read again at most every 10 minutes (the deposit guard's tick) and on Stripe's
// account.updated event; the first "cannot take charges" alerts the Admins once (the database does that).
// Helcim slots in by adding its account read to processorAccount() and its adapter to integrations/payments.
const SR = { role: 'service_role' as const };

export const CARD_OFF_RENTER = 'Card payments are paused for a short while. Pay by Interac e-Transfer on your booking\'s Sign and pay page: the email, the message and the exact amounts are there.';

/** The card state; a database that cannot answer keeps cards as they were (on). */
export async function cardPayments(): Promise<CardPayments | null> {
  return ((await rpc('server_card_payments_state', {} as never, SR).catch(() => null)) as unknown as CardPayments | null);
}
export async function cardPaymentsOn(): Promise<boolean> { return cardOn(await cardPayments()); }

/** What the processor says about the account (charges and payouts enabled); null when it cannot be read here. */
async function processorAccount(provider: 'stripe' | 'helcim'): Promise<{ charges: boolean; payouts: boolean; reason: string | null } | null> {
  const e = env();
  if (provider !== 'stripe' || e.PAYMENTS_PROVIDER !== 'stripe' || !e.STRIPE_SECRET_KEY) return null;
  const get = stripeReader(e.STRIPE_SECRET_KEY, (u, i) => fetch(u, { ...i, signal: AbortSignal.timeout(4000) }));
  const a = await get('/v1/account');
  const req = (a.requirements ?? {}) as Record<string, unknown>;
  return { charges: a.charges_enabled === true, payouts: a.payouts_enabled === true, reason: typeof req.disabled_reason === 'string' ? req.disabled_reason : null };
}

/** Report what the processor said (from a webhook, or a read here) to the database, which alerts once and decides. */
export async function reportProcessor(provider: 'stripe' | 'helcim', charges: boolean, payouts: boolean, reason: string | null) {
  return rpc('server_card_processor_report', { p_provider: provider, p_charges: charges, p_payouts: payouts, p_reason: reason ?? undefined }, SR);
}

/** The deposit guard's tick: read the processor's account when it is due (every 10 minutes), never throwing. */
export async function checkCardProcessor(force = false): Promise<{ checked: boolean; on: boolean; error?: string }> {
  const s = await cardPayments();
  const provider = s?.configured_provider ?? 'stripe';
  try {
    if (!force && (await rpc('server_card_processor_due', { p_provider: provider }, SR).catch(() => true)) !== true) return { checked: false, on: cardOn(s) };
    const a = await processorAccount(provider);
    if (!a) return { checked: false, on: cardOn(s) };
    const after = (await reportProcessor(provider, a.charges, a.payouts, a.reason)) as unknown as CardPayments | null;
    return { checked: true, on: cardOn(after) };
  } catch (x) {
    // an account Stripe refuses to read (a closed account can answer 401/403) counts as not taking charges
    const msg = x instanceof Error ? x.message : String(x);
    if (/not have access|account.*(closed|rejected|disabled)|invalid api key|expired api key/i.test(msg)) {
      await reportProcessor(provider, false, false, msg.slice(0, 200)).catch(() => undefined);
      return { checked: true, on: false, error: msg.slice(0, 200) };
    }
    return { checked: false, on: cardOn(s), error: msg.slice(0, 200) };
  }
}

/** null while cards work; else the renter's sentence for a card step that is paused (add-ons, extensions, tips, gift cards). */
export async function cardOffMessage(what = 'it'): Promise<string | null> {
  const s = await cardPayments();
  if (cardOn(s)) return null;
  return `Card payments are paused for a short while. Pay ${what} by Interac e-Transfer to ${s?.e_transfer_email ?? 'our e-Transfer email'} with your booking number as the message, or call us. Nothing was charged.`;
}
