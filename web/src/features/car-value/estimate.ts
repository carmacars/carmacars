// The AI value estimate of a car (migration 1202), used for the RentalCover $50,000 cap only when the car has no Canadian
// Black Book value: the prompt and the reading of the model's answer. No imports, so the unit test runs it in Node.
export interface CarFacts { year: number; make: string; model: string; trim?: string | null; odometer_km?: number | null; fuel?: string | null; body_type?: string | null }
export interface ValueAnswer { value_cad?: unknown; low_cad?: unknown; high_cad?: unknown; basis?: unknown }

export const VALUE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['value_cad', 'low_cad', 'high_cad', 'basis'],
  properties: { value_cad: { type: 'number' }, low_cad: { type: 'number' }, high_cad: { type: 'number' }, basis: { type: 'string', maxLength: 200 } }
} as const;

export const VALUE_SYSTEM = 'You estimate what a used car sells for in Ontario, Canada today, from typical dealer and private listing prices for the same year, make, model and trim with similar kilometres. Answer in Canadian dollars. If unsure, give a wider range and lean high. Never invent a precise figure you cannot support; the basis says what it rests on in one short sentence.';

export function valuePrompt(c: CarFacts): string {
  const km = c.odometer_km ? `${Math.round(c.odometer_km).toLocaleString('en-CA')} km` : 'kilometres unknown';
  return `The car: ${c.year} ${c.make} ${c.model}${c.trim ? ` ${c.trim}` : ''}${c.body_type ? ` (${c.body_type})` : ''}${c.fuel ? `, ${c.fuel}` : ''}, ${km}. Estimate its current market value.`;
}

/** The value kept, in cents: the high end of the range when it is wider than the middle (unknown leans over the cap), or
 *  null when the answer is not a plausible car price ($1,000 to $1,000,000) or the range is inconsistent. */
export function readValue(a: ValueAnswer | null | undefined): { cents: number; basis: string } | null {
  const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && /^\s*\d+(\.\d+)?\s*$/.test(v) ? Number(v) : NaN);
  const mid = n(a?.value_cad), low = n(a?.low_cad), high = n(a?.high_cad);
  if (!Number.isFinite(mid) || mid < 1000 || mid > 1_000_000) return null;
  const top = Number.isFinite(high) && high >= mid && high <= mid * 2 ? high : mid;
  if (Number.isFinite(low) && low > mid) return null;
  return { cents: Math.round(top * 100), basis: typeof a?.basis === 'string' ? a.basis.slice(0, 200) : '' };
}
