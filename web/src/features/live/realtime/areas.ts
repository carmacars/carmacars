// Live updates (hub.ts): which of the portal's live areas each screen watches, and when a refresh waits for typing.
// The portal frames get one token per area the person may read (server/live.ts); the frame's LivePortal picks the areas
// of the screen shown from its path. A booking's own page watches its booking instead (LiveBooking), so it is not read
// again for every other booking's change. No imports: unit tested in Node (areas.test.ts).

export type LiveArea = 'bookings' | 'requests' | 'leads' | 'messages' | 'field' | 'me' | 'renter' | 'owner';

const STAFF_ROUTES: [RegExp, LiveArea[]][] = [
  // a booking's own page and its sub pages: LiveBooking (the booking's topic)
  [/^\/(admin|staff)\/bookings\/(?!new(\/|$)|past-trips(\/|$))[^/]+/, []],
  [/^\/(admin|staff)\/(bookings|past-trips|payments|deposit-reviews|money)(\/|$)/, ['bookings']],
  [/^\/(admin|staff)\/(requests|offers|quotes|unanswered)(\/|$)/, ['requests', 'bookings']],
  [/^\/(admin|staff)\/(leads|sales-leads|my-sales|owner-leads|game-leads|owner-pipeline|sales-start)(\/|$)/, ['leads']],
  [/^\/(admin|staff)\/(messages|chat|visitors)(\/|$)/, ['messages']],
  [/^\/(admin|staff)\/(calendar|today|live|live-map|overview)(\/|$)/, ['bookings', 'requests', 'field']],
  [/^\/(admin|staff)\/(field-jobs|field|schedule|schedules|field-hours|timesheet|hours|checks)(\/|$)/, ['field']],
  [/^\/(admin|staff)\/?$/, ['bookings', 'requests', 'leads', 'field']]
];

/** The areas a portal screen watches; 'me' (the person's own alerts and messages) is on every portal screen. */
export function areasFor(path: string): LiveArea[] {
  const p = (path.split(/[?#]/)[0] ?? '').replace(/\/+$/, '') || '/';
  if (p.startsWith('/account')) return ['me', 'renter'];
  if (p.startsWith('/owner')) return ['me', 'owner'];
  if (p.startsWith('/admin') || p.startsWith('/staff')) {
    for (const [re, areas] of STAFF_ROUTES) if (re.test(p)) return ['me', ...areas];
    return ['me'];
  }
  return [];
}

/** The tokens to watch: the areas' tokens that the server gave (an area the person may not read has none). */
export function topicsFor(path: string, tokens: Partial<Record<LiveArea, string>>): string[] {
  return areasFor(path).map((a) => tokens[a]).filter((t): t is string => typeof t === 'string' && t.length > 0);
}

/** Longest wait for someone typing before the refresh runs anyway (a refresh keeps what is typed, this only avoids a
 *  jump under the cursor). */
export const TYPING_WAIT_MS = 8000;
/** Refreshes closer together than this run once (the last change is never lost: a trailing refresh follows). */
export const REFRESH_GAP_MS = 1500;

type El = { tagName?: string; isContentEditable?: boolean; type?: string; readOnly?: boolean; disabled?: boolean } | null | undefined;
/** Whether the focused element is a field someone is typing in. */
export function typingIn(el: El): boolean {
  if (!el || el.disabled || el.readOnly) return false;
  if (el.isContentEditable) return true;
  const tag = (el.tagName ?? '').toUpperCase();
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag !== 'INPUT') return false;
  return !['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'color', 'file', 'image', 'hidden'].includes((el.type ?? 'text').toLowerCase());
}
