// Release 26: how a row of the Visitors page's list asks the map for its lead (by the visit, the renter or the
// booking): the map brings it to the middle and opens its card, and says so (found), so the row knows. A tiny module so
// the assistants' Live visitors does not load the map to say it.
export const FOCUS_EVENT = 'carmacars:live-map-focus';
export interface FocusAsk { session_id?: string | null; renter_id?: string | null; booking_number?: string | null; found?: boolean }
/** Brings a lead to the middle of the map and opens its card; false when the map has no such lead (an old visit). */
export function showOnMap(ask: Omit<FocusAsk, 'found'>): boolean {
  const detail: FocusAsk = { ...ask };
  window.dispatchEvent(new CustomEvent(FOCUS_EVENT, { detail }));
  return !!detail.found;
}
