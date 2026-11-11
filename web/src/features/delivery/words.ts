// A delivery or pickup leg in words (1403): the base fee includes the first km from our location, then a rate per km.
// From the leg's detail as app.delivery_fee gives it (the quote, the offer's lines). Pure (words.test.ts).
const cents = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export interface LegDetail { distance_km?: unknown; included_km?: unknown; per_km_cents?: unknown; needs_distance?: unknown; kind?: unknown }

export function deliveryWords(d: LegDetail | null | undefined): string | undefined {
  if (!d) return undefined;
  const incl = typeof d.included_km === 'number' && d.included_km > 0 ? d.included_km : null;
  const perKm = typeof d.per_km_cents === 'number' && d.per_km_cents > 0 ? cents(d.per_km_cents) : null;
  if (d.needs_distance) return `Plus distance from our location${incl ? ` beyond the first ${incl} km` : ''}, priced in your offer`;
  if (typeof d.distance_km !== 'number') return undefined;
  const km = Math.round(d.distance_km * 10) / 10;
  if (!incl || !perKm) return `${km} km from our location`;
  return km > incl ? `${km} km from our location: first ${incl} km included, then ${perKm} a km` : `${km} km from our location, within the ${incl} km included`;
}
