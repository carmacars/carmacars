// Unanswered (1061): how long a customer has waited, in words. Pure (model.test.ts).
export function waitWords(min: number): string {
  const m = Math.max(0, Math.round(min));
  if (m < 60) return `${m} min`;
  if (m < 1440) return `${Math.floor(m / 60)} h ${m % 60} min`;
  return `${Math.floor(m / 1440)} d ${Math.floor((m % 1440) / 60)} h`;
}

/** Calls first (r37): a missed call waiting for a call-back is listed above a text waiting for an answer; inside each, the one
 *  waiting longest first. The database sorts the same way (migration 2321). */
export function sortUnanswered<T extends { kind: string; waiting_since: string }>(rows: T[]): T[] {
  return [...rows].sort((a, b) => (Number(a.kind !== 'missed_call') - Number(b.kind !== 'missed_call')) || Date.parse(a.waiting_since) - Date.parse(b.waiting_since));
}
