import 'server-only';
import { env, required } from '@/lib/env';
import type { PaymentsAdapter } from './types';
import { fakePayments } from './fake';

let cached: PaymentsAdapter | undefined;
export async function payments(): Promise<PaymentsAdapter> {
  if (cached) return cached;
  if (env().PAYMENTS_PROVIDER === 'stripe') {
    const { stripeAdapter } = await import('./stripe');
    cached = stripeAdapter(required('STRIPE_SECRET_KEY'));
  } else cached = fakePayments();
  return cached;
}
export type * from './types';
