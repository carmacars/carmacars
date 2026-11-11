import 'server-only';
import { env } from '@/lib/env';
import { requestQuote, type FetchLike, type QuoteInput, type QuoteResult } from './client';

export type { QuoteInput, QuoteResult } from './client';

/** Whether a quote can be asked: the partner key is set (a Worker secret). */
export const rentalcoverConfigured = () => !!env().RENTALCOVER_API_KEY;

/** A RentalCover quote with the key and base URL from the environment. Unset key: a failure the caller falls back on. */
export async function rentalcoverQuote(q: QuoteInput): Promise<QuoteResult> {
  const e = env();
  if (!e.RENTALCOVER_API_KEY) return { ok: false, error: 'RENTALCOVER_API_KEY is not set' };
  return requestQuote(e.RENTALCOVER_API_BASE, e.RENTALCOVER_API_KEY, q, fetch as unknown as FetchLike);
}
