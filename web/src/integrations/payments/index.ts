import 'server-only';
import { env, required } from '@/lib/env';
import type { PaymentsAdapter } from './types';
import type { TerminalAdapter } from './terminal';
import type { FakePayments } from './fake';
import type { HelcimAdapter } from './helcim';
import { cardProvider, CardsOffError, type CardProvider } from './provider';

/** r50: the card processor in use (provider.ts): helcim, stripe, off or fake. */
export const provider = (): CardProvider => cardProvider(env());

/** Cards off (PAYMENTS_PROVIDER=off, or a processor with no key): every card call says so; the pages offer e-Transfer. */
function offAdapter(): PaymentsAdapter {
  const off = async (): Promise<never> => { throw new CardsOffError(); };
  return new Proxy({ name: 'off' } as PaymentsAdapter, { get: (t, k) => (k === 'name' ? 'off' : k === 'then' ? undefined : (t as unknown as Record<string, unknown>)[k as string] ?? off) });
}

let cached: PaymentsAdapter | undefined;
export async function payments(): Promise<PaymentsAdapter> {
  if (cached) return cached;
  const p = provider();
  if (p === 'helcim') {
    const [{ helcimAdapter }, { dbHelcimStore }] = await Promise.all([import('./helcim'), import('./helcim-store')]);
    const t = env().HELCIM_TERMINAL_ID;
    cached = helcimAdapter(required('HELCIM_API_TOKEN'), dbHelcimStore(), { terminalId: t ? Number(t) : undefined });
  } else if (p === 'off') {
    cached = offAdapter();
  } else if (p === 'stripe') {
    const { stripeAdapter } = await import('./stripe');
    cached = stripeAdapter(required('STRIPE_SECRET_KEY'));
  } else {
    // r35: loaded only where it is used (local and tests): imported at the top, its test-card table was compiled into 63
    // route chunks of the Worker (about 0.4 MiB)
    const { fakePayments } = await import('./fake');
    cached = fakePayments();
  }
  return cached;
}

/** The Helcim adapter, only when Helcim is the processor (the confirm and webhook routes, the connector). */
export async function helcimOnly(): Promise<HelcimAdapter | null> {
  const p = await payments();
  return p.name === 'helcim' ? (p as HelcimAdapter) : null;
}

/** r50: Helcim's account as the card-off seam reads a processor (hotfix-nocard's processorAccount): whether it takes
 *  charges. Helcim has no account-status API: a working connection test counts as taking charges; a refused token as not. */
export async function helcimAccount(): Promise<{ charges: boolean; payouts: boolean; reason: string | null } | null> {
  const h = await helcimOnly();
  if (!h) return null;
  try { await h.connectionTest(); return { charges: true, payouts: true, reason: null }; }
  catch (e) {
    const status = (e as { status?: number }).status ?? 0;
    if (status === 401 || status === 403) return { charges: false, payouts: false, reason: `Helcim refused the API token (${status})` };
    throw e;
  }
}

/** The fake adapter, only when it is the one in use (local and tests). */
export async function fakeOnly(): Promise<FakePayments | null> {
  const p = await payments();
  return p.name === 'fake' ? (p as FakePayments) : null;
}

let terminalCached: TerminalAdapter | undefined;
/** Stripe Terminal (0202) and the lookup of a payment taken outside the site (0201), on the same keys as payments(). */
export async function terminal(): Promise<TerminalAdapter> {
  if (terminalCached) return terminalCached;
  const p = provider();
  if (p === 'stripe') {
    const { stripeTerminal } = await import('./terminal');
    terminalCached = stripeTerminal(required('STRIPE_SECRET_KEY'));
  } else if (p !== 'fake') {
    // r50: Stripe Terminal readers belong to Stripe; with Helcim (or cards off) a card on a reader is taken on Helcim's own
    // terminal and recorded with the connector's helcim_record_paid
    const no = async (): Promise<never> => { throw new Error('Card readers are Stripe\'s and Stripe is not the card processor: take the card on the Helcim terminal, then record it (helcim_record_paid)'); };
    terminalCached = new Proxy({ name: 'stripe' } as unknown as TerminalAdapter, { get: (t, k) => (k === 'then' ? undefined : k === 'name' ? 'off' : (t as unknown as Record<string, unknown>)[k as string] ?? no) });
  } else {
    const { fakeTerminal } = await import('./terminal-fake');
    terminalCached = fakeTerminal();
  }
  return terminalCached;
}
export type * from './types';
export { CardsOffError, type CardProvider } from './provider';
export type { Reader, TerminalAdapter, TerminalAddress } from './terminal';
