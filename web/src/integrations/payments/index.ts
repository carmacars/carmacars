import 'server-only';
import { env, required } from '@/lib/env';
import type { PaymentsAdapter } from './types';
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
export type * from './types';
