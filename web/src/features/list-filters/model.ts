// r32 "Simple": one way to filter every list (ListFilters). Pure: the component and the unit tests share it.
//   one search box across fields; one row of at most 5 chips; at most one date range (where dates matter) and one sort
//   with 2 or 3 options; nothing else. Old query parameters still work (mapped, or still read by the list).
export type Opt = readonly [value: string, label: string];
export interface Group { name: string; label: string; options: ReadonlyArray<Opt> }

export const MAX_CHIPS = 5;

/** Old parameters to the new ones: { old: 'new' } renames, { old: { value: ['new', 'newValue'] } } maps one value. */
export type Legacy = Record<string, string | Record<string, readonly [string, string]>>;
export function mapLegacy(sp: Record<string, string | undefined>, legacy: Legacy): { sp: Record<string, string>; changed: boolean } {
  const out: Record<string, string> = {};
  let changed = false;
  for (const [k, v] of Object.entries(sp)) {
    if (typeof v !== 'string' || v === '') continue;
    const rule = legacy[k];
    if (typeof rule === 'string') { if (!out[rule]) out[rule] = v; changed = true; continue; }
    if (rule && rule[v]) { const [nk, nv] = rule[v]!; out[nk] = nv; changed = true; continue; }
    out[k] = v;
  }
  return { sp: out, changed };
}

/** The address with one parameter set (empty: removed), the others kept. */
export function hrefWith(base: string, sp: Record<string, string | undefined>, name: string, value: string): string {
  const [path = base, own = ''] = base.split('?');
  const q = new URLSearchParams(Object.entries(sp).filter(([k, x]) => k !== name && typeof x === 'string' && x) as Array<[string, string]>);
  for (const [k, x] of new URLSearchParams(own)) if (!q.has(k)) q.set(k, x);
  if (value) q.set(name, value); else q.delete(name);
  const s = q.toString();
  return s ? `${path}?${s}` : path;
}

/** How many filters other than the search are in use (for "More filters (2)" and the Clear link). */
export function activeCount(sp: Record<string, string | undefined>, names: string[]): number {
  return names.filter((n) => typeof sp[n] === 'string' && sp[n] !== '').length;
}

/** A list follows the rule: at most 5 chips, at most one date range, a sort of at most 3 options. */
export function withinRule(chips: number, dateRanges: number, sortOptions: number): boolean {
  return chips <= MAX_CHIPS && dateRanges <= 1 && sortOptions <= 3;
}
