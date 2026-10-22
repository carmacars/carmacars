// The vehicle pages' (migration 0097) small rules, shared by the pages, the catalog import (web/scripts/catalog) and
// the unit tests. No imports: it runs in Node with --experimental-strip-types and in the app.

/** The same slug as app.slugify in SQL (0022): accents folded, anything but a-z and 0-9 becomes one hyphen. */
export function slugify(s: string | null | undefined): string {
  const from = 'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÇçÑñ';
  const to = 'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn';
  let t = '';
  for (const ch of String(s ?? '')) { const i = from.indexOf(ch); t += i >= 0 ? to[i] : ch; }
  return t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

/** A trim's slug: as slugify, with "+" read as "plus" so "EX+" and "EX" stay two pages (app.vehicle_trim_slug in SQL). */
export const trimSlug = (s: string | null | undefined) => slugify(String(s ?? '').replace(/\+/g, ' plus '));

/** A model's matching key: its slug without hyphens, so "F-150", "F150" and "f 150" are one model. */
export const modelKey = (s: string | null | undefined) => slugify(s).replace(/-/g, '');

/** A US EPA miles-per-gallon rating as litres per 100 km (one decimal). */
export function mpgToL100(mpg: number | null | undefined): number | null {
  if (!mpg || !Number.isFinite(mpg) || mpg <= 0) return null;
  return Math.round((235.214583 / mpg) * 10) / 10;
}

/** An EPA electricity use in kWh per 100 miles as kWh per 100 km (one decimal). */
export function kwh100miTo100km(v: number | null | undefined): number | null {
  if (!v || !Number.isFinite(v) || v <= 0) return null;
  return Math.round((v / 1.609344) * 10) / 10;
}

/** Miles to kilometres, whole. */
export const miToKm = (mi: number | null | undefined) => (!mi || !Number.isFinite(mi) || mi <= 0 ? null : Math.round(mi * 1.609344));

/** The energy cost of 100 km in cents: litres times the gas price, or kWh times the electricity price. */
export function costPer100km(o: { l100?: number | null; kwh100?: number | null; gasCents: number; elecCents: number; premium?: boolean; premiumExtraCents?: number }): number | null {
  if (o.kwh100) return Math.round(o.kwh100 * o.elecCents);
  if (o.l100) return Math.round(o.l100 * (o.gasCents + (o.premium ? (o.premiumExtraCents ?? 0) : 0)));
  return null;
}

/** "1.4L 4-cylinder turbo" style engine words from EPA fields; "Electric motor" for an EV. */
export function engineLabel(v: { displ?: number | null; cyl?: number | null; turbo?: boolean; super?: boolean; ev?: boolean; hybrid?: boolean }): string {
  if (v.ev) return 'Electric motor';
  const parts: string[] = [];
  if (v.displ) parts.push(`${v.displ.toFixed(1)}L`);
  // "6-cylinder", not "V6": a flat or inline six is a six too, and EPA does not say which
  if (v.cyl) parts.push(`${v.cyl}-cylinder`);
  if (v.turbo) parts.push('turbo');
  if (v.super) parts.push('supercharged');
  if (v.hybrid) parts.push('hybrid');
  return parts.join(' ') || 'Engine';
}

/** EPA drive words as one short label. */
export function driveLabel(d: string | null | undefined): string | null {
  const s = String(d ?? '').toLowerCase();
  if (!s) return null;
  if (/front/.test(s)) return 'Front-wheel drive';
  if (/4-wheel|4wd|four/.test(s) && !/all/.test(s)) return 'Four-wheel drive';
  if (/all|awd/.test(s)) return 'All-wheel drive';
  if (/rear|2-wheel/.test(s)) return 'Rear-wheel drive';
  return null;
}

/** EPA transmission words ("Automatic (S8)", "Manual 6-spd", "Automatic (variable gear ratios)") as plain words. */
export function transLabel(t: string | null | undefined): string | null {
  const s = String(t ?? '');
  if (!s) return null;
  if (/variable|AV|CVT/i.test(s)) return 'Automatic (CVT)';
  const n = /(\d+)/.exec(s)?.[1];
  if (/^manual/i.test(s)) return n ? `${n}-speed manual` : 'Manual';
  if (/^auto/i.test(s)) return n ? `${n}-speed automatic` : 'Automatic';
  return s;
}

/** The kind of body from the EPA size class, for "similar cars" and the stand-in image. */
export function bodyGroup(vclass: string | null | undefined): 'pickup' | 'van' | 'suv' | 'wagon' | 'sports' | 'car' {
  const s = String(vclass ?? '').toLowerCase();
  if (/pickup/.test(s)) return 'pickup';
  if (/van|special purpose/.test(s)) return /minivan/.test(s) ? 'van' : (/sport utility/.test(s) ? 'suv' : 'van');
  if (/sport utility|suv/.test(s)) return 'suv';
  if (/wagon/.test(s)) return 'wagon';
  if (/two seaters|minicompact/.test(s)) return 'sports';
  return 'car';
}

/** Makes sold as premium brands in Canada: the price band for "similar cars" when a page has no price of its own. */
export const PREMIUM_MAKES = new Set(['acura', 'alfa-romeo', 'audi', 'bmw', 'cadillac', 'genesis', 'infiniti', 'jaguar', 'land-rover', 'lexus', 'lincoln',
  'lucid', 'mercedes-benz', 'polestar', 'porsche', 'rivian', 'tesla', 'volvo', 'maserati']);
