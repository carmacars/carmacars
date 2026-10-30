import 'server-only';
import { env, required } from '@/lib/env';
import type { PaymentsAdapter } from './types';
import type { TerminalAdapter } from './terminal';
import { fakePayments, type FakePayments } from './fake';

let cached: PaymentsAdapter | undefined;
export async function payments(): Promise<PaymentsAdapter> {
  if (cached) return cached;
  if (env().PAYMENTS_PROVIDER === 'stripe') {
    const { stripeAdapter } = await import('./stripe');
    cached = stripeAdapter(required('STRIPE_SECRET_KEY'));
  } else cached = fakePayments();
  return cached;
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
  if (env().PAYMENTS_PROVIDER === 'stripe') {
    const { stripeTerminal } = await import('./terminal');
    terminalCached = stripeTerminal(required('STRIPE_SECRET_KEY'));
  } else {
    const { fakeTerminal } = await import('./terminal-fake');
    terminalCached = fakeTerminal();
  }
  return terminalCached;
}
export type * from './types';
export type { Reader, TerminalAdapter, TerminalAddress } from './terminal';
