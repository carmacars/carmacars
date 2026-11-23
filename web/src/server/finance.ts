import 'server-only';
import { env } from '@/lib/env';
import { stripeReader } from '@/features/api-access/stripe-inspect';
import { stripeCash, type StripeCash } from '@/features/finance/stripe-cash';
import { door, type Call } from '@/server/door';
import type { BankProvider } from '@/integrations/bank/types';

// Release 49 (3480): the Finance dashboard's server side. Stripe is read live (GET only, with the server's key; a slow or
// failing Stripe never blocks the page: 4 seconds, then the page says it could not be read); the bank comes from the
// database (imports and feeds).

/** Stripe's balance and the payouts on their way; null when Stripe is not the payments provider here, or it did not answer. */
export async function loadStripeCash(): Promise<StripeCash | { error: string } | null> {
  const e = env();
  if (e.PAYMENTS_PROVIDER !== 'stripe' || !e.STRIPE_SECRET_KEY) return null;
  const get = stripeReader(e.STRIPE_SECRET_KEY, (u, i) => fetch(u, { ...i, signal: AbortSignal.timeout(4000) }));
  try { return await stripeCash(get); } catch (x) { return { error: x instanceof Error ? x.message : 'Stripe did not answer' }; }
}

/** A live bank feed's new lines and balance, through the same import as a file (dedupe and matching are the database's). */
export async function syncBankFeed(userId: string, call: Extract<Call, 'admin_do' | 'va_do'>, provider: BankProvider, aal?: 'aal1' | 'aal2' | null) {
  const { bankFeed } = await import('@/integrations/bank');
  const feed = await bankFeed(provider);
  if (!feed.connected) throw new Error(`No live bank feed is connected (${provider}): import the CSV or OFX download.`);
  const from = new Date(Date.now() - 60 * 86400000).toISOString().slice(0, 10);
  let lines_new = 0, lines_matched = 0;
  const accounts = await feed.accounts();
  for (const a of accounts) {
    const [lines, bal] = await Promise.all([feed.transactions(a.ref, from), feed.balance(a.ref)]);
    const r = await door<{ lines_new: number; lines_matched: number }>(userId, call, 'bank_import', {
      account: { last4: a.last4, currency: a.currency, nickname: a.nickname, institution: provider === 'fake' ? 'fake' : 'rbc' },
      source: 'api', file_name: `${provider} feed`, balance_cents: bal.balance_cents, available_cents: bal.available_cents, balance_on: bal.as_of, balance_source: 'api', lines
    }, aal);
    lines_new += r.lines_new; lines_matched += r.lines_matched;
  }
  return { accounts: accounts.length, lines_new, lines_matched };
}
