// The one-screen handover (migration 2710): what the screen prefills and what is still needed before the keys change
// hands. The database gives the defaults (app.handover_defaults: the Tracker, else the car's last report or the pickup);
// this turns them into answers and into the words under each field. Pure: one-screen.test.ts.
export interface HandoverDefaults {
  odometer_km: number | null; odometer_from: 'tracker' | 'last_report' | null;
  fuel_pct: number | null; fuel_from: 'tracker' | 'pickup' | 'last_report' | 'full' | null;
  keys_count: number | null; keys_from: 'pickup' | 'last_report' | 'one' | null;
  cleanliness: string | null; tracker_at: string | null;
}
export interface Prefilled { odometer_km?: number; fuel_pct?: number; keys_count?: number; cleanliness?: string; renter_present?: boolean }

/** A fuel level as the gauge reads it: the nearest eighth, in percent (the same rounding as the fuel control). */
export const toEighths = (pct: number) => Math.round(Math.round(Math.min(100, Math.max(0, pct)) / 12.5) * 12.5);

/** The answers the screen starts with. A return starts with the renter present (staff untick it when the car was left). */
export function prefill(d: HandoverDefaults | null | undefined, kind: 'pickup' | 'return', attended: boolean): Prefilled {
  const out: Prefilled = {};
  if (d?.odometer_km && d.odometer_km > 0) out.odometer_km = Math.round(d.odometer_km);
  if (d?.fuel_pct !== null && d?.fuel_pct !== undefined) out.fuel_pct = toEighths(d.fuel_pct);
  if (d?.keys_count && d.keys_count > 0) out.keys_count = d.keys_count;
  if (kind === 'return') {
    out.cleanliness = d?.cleanliness ?? 'clean';
    if (attended) out.renter_present = true;
  }
  return out;
}

/** Prefilled answers, then what the server has, then what this phone kept: a missing value never hides a filled one. */
export function mergeAnswers<T extends object>(...layers: Array<Partial<T> | null | undefined>): T {
  const out: Record<string, unknown> = {};
  for (const l of layers) for (const [k, v] of Object.entries(l ?? {})) if (v !== undefined && v !== null && v !== '') out[k] = v;
  return out as T;
}

/** Under a prefilled field: where the value came from and that it is to be checked. Null once staff changed it. */
export function sourceHint(field: 'odometer' | 'fuel' | 'keys', d: HandoverDefaults | null | undefined, value: number | undefined): string | null {
  if (!d || value === undefined) return null;
  if (field === 'odometer') {
    if (!d.odometer_km || value !== Math.round(d.odometer_km)) return null;
    return d.odometer_from === 'tracker' ? 'Filled in from the Tracker. Check it against the dash.' : 'Filled in from the car\'s last report. Check it against the dash.';
  }
  if (field === 'fuel') {
    if (d.fuel_pct === null || value !== toEighths(d.fuel_pct)) return null;
    return d.fuel_from === 'tracker' ? 'Filled in from the Tracker. Check it against the gauge.'
      : d.fuel_from === 'pickup' ? 'Set to the level at pickup. Change it if the gauge shows less.'
      : d.fuel_from === 'last_report' ? 'Filled in from the car\'s last report. Check it against the gauge.'
      : 'Set to full. Change it if the gauge shows less.';
  }
  if (!d.keys_count || value !== d.keys_count) return null;
  return d.keys_from === 'pickup' ? 'As handed over at pickup. Change it if a key is missing.' : d.keys_from === 'last_report' ? 'As on the car\'s last report.' : null;
}

export interface Part { id: string; title: string; ok: boolean; optional?: boolean; need?: string }
/** What still stops the last button, in the order of the screen. */
export const stillNeeded = (parts: readonly Part[]) => parts.filter((p) => !p.ok && !p.optional).map((p) => ({ id: p.id, label: p.need ?? p.title }));
