// Release 49 (3480): Stripe's side of the cash position: the balance (available and pending) and the payouts on their
// way to the bank. GET only (stripe-inspect.ts's reader), so nothing is ever moved. Pure apart from the reader: unit
// tested with a faked Stripe (stripe-cash.test.ts).
import type { StripeGet } from '@/features/api-access/stripe-inspect';

export interface StripeCash { available_cents: number; pending_cents: number; in_transit_cents: number; in_transit_count: number; next_arrival: string | null; currency: 'cad' }

type O = Record<string, unknown>;
const arr = (v: unknown): O[] => (Array.isArray(v) ? (v.filter((x) => x && typeof x === 'object') as O[]) : []);
const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
const cad = (l: unknown) => arr(l).filter((x) => x.currency === 'cad').reduce((t, x) => t + n(x.amount), 0);

export async function stripeCash(get: StripeGet): Promise<StripeCash> {
  const [bal, po] = await Promise.all([get('/v1/balance'), get('/v1/payouts', { limit: '20' }).catch(() => null)]);
  const open = arr(po?.data).filter((p) => (p.status === 'pending' || p.status === 'in_transit') && p.currency === 'cad');
  const next = open.map((p) => n(p.arrival_date)).filter((x) => x > 0).sort((a, b) => a - b)[0];
  return { available_cents: cad(bal.available), pending_cents: cad(bal.pending), in_transit_cents: open.reduce((t, p) => t + n(p.amount), 0),
    in_transit_count: open.length, next_arrival: next ? new Date(next * 1000).toISOString().slice(0, 10) : null, currency: 'cad' };
}
