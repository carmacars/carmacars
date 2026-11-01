// Lead-time pricing (migration 0360): the tiers as Admin edits them. A tier applies from so many hours before pickup
// (Toronto clocks) until the next tier starts; its percentage is of the rental charge only, before tax. The database
// checks the table again (app.lead_time_tiers_ok); these are the same rules, worded for the screen.
export interface Tier { from_hours: number; bps: number }
export interface TierRow { from: string; pct: string }

export const DEFAULT_TIERS: Tier[] = [{ from_hours: 0, bps: 1500 }, { from_hours: 24, bps: 1000 }, { from_hours: 72, bps: 0 }, { from_hours: 336, bps: -500 }];
export const MAX_TIERS = 8;
const MINUS = '−';

/** 24 → "24 hours", 72 → "3 days" (whole days from 72 hours up), 1 → "1 hour". */
export function hoursText(h: number): string {
  if (h >= 72 && h % 24 === 0) return `${h / 24} days`;
  return h === 1 ? '1 hour' : `${h} hours`;
}

/** When a tier applies, in words: "Under 24 hours", "24 to 72 hours", "3 to 13 days", "14 days or more". */
export function tierRange(from: number, next: number | null): string {
  if (next === null) return from === 0 ? 'Any time' : `${hoursText(from)} or more`;
  if (from === 0) return `Under ${hoursText(next)}`;
  if (from >= 72 && from % 24 === 0 && next % 24 === 0) {
    const a = from / 24, b = next / 24 - 1;
    return a === b ? `${a} days` : `${a} to ${b} days`;
  }
  return `${from} to ${next} hours`;
}

/** 1500 → "+15%", 0 → "0%", -500 → "−5%" (a minus sign). */
export function pctText(bps: number): string {
  const v = Math.abs(bps) / 100;
  const n = Number.isInteger(v) ? String(v) : String(Math.round(v * 100) / 100);
  return bps > 0 ? `+${n}%` : bps < 0 ? `${MINUS}${n}%` : '0%';
}

/** The words the price line uses (the same as app.lead_time_text). */
export function lineText(bps: number): string {
  return bps > 0 ? `Short-notice pricing ${pctText(bps)}` : bps < 0 ? `Booked ahead ${pctText(bps)}` : 'No lead-time adjustment';
}

export const toRows = (t: Tier[] | null | undefined): TierRow[] => (t && t.length ? t : DEFAULT_TIERS).map((x) => ({ from: String(x.from_hours), pct: String(x.bps / 100) }));

const num = (s: string) => s.trim().replace(MINUS, '-').replace(/^\+/, '');

/** The rows typed, as the database takes them, or the first problem in words. */
export function toTiers(rows: TierRow[]): { tiers: Tier[] } | { error: string } {
  if (!rows.length) return { error: 'Keep at least one tier.' };
  if (rows.length > MAX_TIERS) return { error: `At most ${MAX_TIERS} tiers.` };
  const out: Tier[] = [];
  for (const [i, r] of rows.entries()) {
    const f = num(r.from), p = num(r.pct);
    if (!/^\d+$/.test(f)) return { error: `Tier ${i + 1}: enter the hours before pickup as a whole number.` };
    if (!/^-?\d+(\.\d{1,2})?$/.test(p)) return { error: `Tier ${i + 1}: enter the percentage, for example 10 or -5.` };
    const from_hours = Number(f), bps = Math.round(Number(p) * 100);
    if (i === 0 && from_hours !== 0) return { error: 'The first tier starts at 0 hours (a pickup that is close).' };
    if (i > 0 && from_hours <= out[i - 1]!.from_hours) return { error: `Tier ${i + 1}: start later than the tier above it.` };
    if (from_hours > 8784) return { error: `Tier ${i + 1}: at most 8,784 hours (a year) before pickup.` };
    if (bps < -5000 || bps > 5000) return { error: `Tier ${i + 1}: between -50% and +50%.` };
    out.push({ from_hours, bps });
  }
  return { tiers: out };
}

/** The tier for so many hours ahead (a pickup already passed: the first), as the database picks it. */
export function tierFor(tiers: Tier[], hours: number): Tier {
  let t = tiers[0] ?? { from_hours: 0, bps: 0 };
  for (const x of tiers) if (x.from_hours <= Math.max(hours, 0)) t = x;
  return t;
}
