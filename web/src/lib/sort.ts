// r43: one sort for every list of people and records. The choice lives in the address only (?sort=newest|oldest|active|az),
// never anything personal. Pure, shared by the Table, the pages that order in SQL, and the unit tests.
export type SortKey = 'newest' | 'oldest' | 'active' | 'az';
export const SORT_KEYS: readonly SortKey[] = ['newest', 'oldest', 'active', 'az'];
export const SORT_LABEL: Record<SortKey, string> = { newest: 'Newest first', oldest: 'Oldest first', active: 'Recently active', az: 'A to Z' };

/** The ?sort= value as a sort, or null (anything else is ignored). */
export function parseSort(v: string | null | undefined): SortKey | null {
  return SORT_KEYS.includes(v as SortKey) ? (v as SortKey) : null;
}

/** The first field of a row that names when it began / when it was last active / what it is called. */
export const CREATED_KEYS = ['created_at', 'joined_at', 'applied_at', 'submitted_at', 'requested_at', 'first_seen_at', 'added_at', 'invited_at', 'started_at', 'asked_at', 'sent_at', 'signed_at', 'since'] as const;
export const ACTIVE_KEYS = ['last_active_at', 'last_activity_at', 'last_sign_in_at', 'last_seen_at', 'last_contact_at', 'last_message_at', 'updated_at', 'last_at'] as const;
export const NAME_KEYS = ['full_name', 'legal_name', 'name', 'title', 'label', 'company', 'vehicle_name', 'car', 'email'] as const;

export interface SortFields { created: string | null; active: string | null; name: string | null }

const has = (r: Record<string, unknown>, k: string) => r[k] !== undefined && r[k] !== null && r[k] !== '';

/** Which fields the rows can be sorted by (the first key that any row carries). */
export function sortFields(rows: ReadonlyArray<Record<string, unknown>>): SortFields {
  const pick = (keys: readonly string[]) => keys.find((k) => rows.some((r) => has(r, k))) ?? null;
  return { created: pick(CREATED_KEYS), active: pick(ACTIVE_KEYS), name: pick(NAME_KEYS) };
}

/** The sorts a list offers: Newest/Oldest need a start time (or an activity time), Recently active an activity time, A to Z a name. */
export function sortOptions(f: SortFields): SortKey[] {
  const out: SortKey[] = [];
  if (f.created || f.active) out.push('newest', 'oldest');
  if (f.active) out.push('active');
  if (f.name && out.length) out.push('az');
  return out;
}

export interface SortValues { c: number | null; a: number | null; n: string | null }
const time = (v: unknown): number | null => {
  if (typeof v === 'number') return v;
  if (typeof v !== 'string' || !v) return null;
  const t = Date.parse(v.length === 10 ? `${v}T12:00:00Z` : v);
  return Number.isNaN(t) ? null : t;
};
/** One row's sort values (numbers and a lowercase name, safe to pass to the browser). */
export function valuesOf(r: Record<string, unknown>, f: SortFields): SortValues {
  const c = time(f.created ? r[f.created] : null) ?? time(f.active ? r[f.active] : null);
  const a = time(f.active ? r[f.active] : null) ?? time(f.created ? r[f.created] : null);
  const nv = f.name ? r[f.name] : null;
  return { c, a, n: nv === null || nv === undefined || nv === '' ? null : String(nv).toLowerCase() };
}

/** Order items by a sort; rows without the value go last; ties keep their order. */
export function sortItems<T>(items: readonly T[], sort: SortKey | null, get: (x: T) => SortValues): T[] {
  if (!sort) return [...items];
  const idx = new Map(items.map((x, i) => [x, i] as const));
  const cmp = (a: T, b: T): number => {
    if (sort === 'az') {
      const x = get(a).n, y = get(b).n;
      if (x === null || y === null) return x === y ? 0 : x === null ? 1 : -1;
      return x.localeCompare(y, 'en', { numeric: true, sensitivity: 'base' });
    }
    const k = sort === 'active' ? 'a' : 'c';
    const x = get(a)[k], y = get(b)[k];
    if (x === null || y === null) return x === y ? 0 : x === null ? 1 : -1;
    return sort === 'oldest' ? x - y : y - x;
  };
  return [...items].sort((a, b) => cmp(a, b) || (idx.get(a)! - idx.get(b)!));
}

/** Sort plain rows by the fields they carry. */
export function sortRows<T extends object>(rows: readonly T[], sort: SortKey | null, f?: SortFields): T[] {
  const fields = f ?? sortFields(rows as ReadonlyArray<Record<string, unknown>>);
  return sortItems(rows, sort, (r) => valuesOf(r as Record<string, unknown>, fields));
}

/** For a list ordered in SQL: the column and direction a sort asks for (the columns this list has), else the default. */
export function sqlOrder(sort: string | null | undefined, cols: { created: string; active?: string; name?: string }, fallback: SortKey = 'newest'): { order: string; asc: boolean } {
  const s = parseSort(sort) ?? fallback;
  if (s === 'az' && cols.name) return { order: cols.name, asc: true };
  if (s === 'active' && cols.active) return { order: cols.active, asc: false };
  return { order: cols.created, asc: s === 'oldest' };
}
