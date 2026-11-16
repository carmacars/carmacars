/** r48 (3071): a reviewed document opened again: a one-minute private link, or the day it was removed (the 90-day purge). */
export interface DocViewResult { url: string | null; mime_type: string | null; removed_on: string | null }

/** "Removed on Nov 3, 2026" from a date (YYYY-MM-DD) or a timestamp, in Toronto. */
export function removedOn(at: string): string {
  const d = new Date(at.length === 10 ? `${at}T12:00:00Z` : at);
  return `Removed on ${new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(d)}`;
}
