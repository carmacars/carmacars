// What a request or booking still needs from the renter (migration 1203): the database's list (app.renter_still_needed,
// read with the booking as still_needed) put in order for the checklist at the top of /account and of each booking.
// No imports, so the unit test runs it in Node. The database decides each item's status; this orders them (what to do
// first), works out the progress and where each action goes.

export type NeedStatus = 'missing' | 'review' | 'rejected' | 'done';
export interface NeedItem { key: string; label: string; status: NeedStatus; reason: string | null; action: { label: string; path: string } | null }
export interface StillNeeded { items: NeedItem[]; done: number; total: number; complete: boolean }

/** What the renter sees for each status. */
export const NEED_STATUS: Record<NeedStatus, { word: string; tone: 'todo' | 'wait' | 'bad' | 'ok' }> = {
  missing: { word: 'Needed', tone: 'todo' },
  rejected: { word: 'Not accepted', tone: 'bad' },
  review: { word: 'Under review', tone: 'wait' },
  done: { word: 'Done', tone: 'ok' }
};
const ORDER: Record<NeedStatus, number> = { rejected: 0, missing: 1, review: 2, done: 3 };

/** The list as the database sent it, or null when there is none (an old read, or a booking with nothing to do). */
export function stillNeededOf(b: { still_needed?: Partial<StillNeeded> | null } | null | undefined): StillNeeded | null {
  const s = b?.still_needed;
  if (!s || !Array.isArray(s.items) || s.items.length === 0) return null;
  const items = s.items.filter((i): i is NeedItem => !!i && typeof i.key === 'string' && typeof i.label === 'string' && i.status in NEED_STATUS)
    .map((i) => ({ ...i, reason: i.reason ?? null, action: i.action && typeof i.action.path === 'string' ? i.action : null }));
  const done = items.filter((i) => i.status === 'done').length;
  return { items, done, total: items.length, complete: done === items.length };
}

/** Rejected first (it needs sending again), then needed, then under review, then done; the database's order within each. */
export function orderNeeds(items: NeedItem[]): NeedItem[] {
  return items.map((i, n) => ({ i, n })).sort((a, b) => ORDER[a.i.status] - ORDER[b.i.status] || a.n - b.n).map((x) => x.i);
}

/** Percent done, for the bar: an item under review counts half (sent, not yet accepted). */
export function needProgress(s: StillNeeded): number {
  if (!s.total) return 100;
  const pts = s.items.reduce((sum, i) => sum + (i.status === 'done' ? 1 : i.status === 'review' ? 0.5 : 0), 0);
  return Math.round((100 * pts) / s.total);
}

/** What is left for the renter to do (not done and not waiting on us). */
export const needsAction = (s: StillNeeded) => s.items.filter((i) => i.status === 'missing' || i.status === 'rejected').length;

/** An action's link: an /account path as it is, "#part" on the booking page, else a page under the booking. */
export function needHref(number: string, path: string): string {
  if (path.startsWith('/')) return path;
  const base = `/account/bookings/${encodeURIComponent(number)}`;
  return path.startsWith('#') ? `${base}${path}` : `${base}/${path}`;
}

/** The checklist shows while anything is not done. */
export const showNeeds = (s: StillNeeded | null): s is StillNeeded => !!s && !s.complete;
