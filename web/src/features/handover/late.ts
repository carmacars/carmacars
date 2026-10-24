// Late returns (migration 0130): how late a car came back against its due-back time, or how long it is overdue while
// still out. The fee itself is the database's (the grace period of the fee defaults, app.complete_return); this is
// what staff and the renter read: "Late by 2 h 10 min", "Overdue by 45 min".
export interface LateFacts { status: string; return_at: string; checked_in_at?: string | null; minutes_late?: number | null }

/** Minutes between the due-back time and the check-in (or now, while the car is still out); 0 when on time. */
export function lateMinutes(b: LateFacts, now: Date = new Date()): number {
  if (b.checked_in_at) {
    if (typeof b.minutes_late === 'number') return Math.max(0, b.minutes_late);
    return Math.max(0, Math.floor((Date.parse(b.checked_in_at) - Date.parse(b.return_at)) / 60_000));
  }
  if (b.status !== 'on_rent') return 0;
  return Math.max(0, Math.floor((now.getTime() - Date.parse(b.return_at)) / 60_000));
}

/** 45 min, 2 h 10 min, 1 d 3 h. */
export function fmtDuration(min: number): string {
  const m = Math.max(0, Math.floor(min));
  if (m < 60) return `${m} min`;
  if (m < 1440) return `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ''}`;
  const h = Math.floor((m % 1440) / 60);
  return `${Math.floor(m / 1440)} d${h ? ` ${h} h` : ''}`;
}

/** "Late by 2 h 10 min" once back, "Overdue by 45 min" while out; null when on time. */
export function lateLabel(b: LateFacts, now: Date = new Date()): string | null {
  const m = lateMinutes(b, now);
  if (m <= 0) return null;
  return b.checked_in_at ? `Late by ${fmtDuration(m)}` : `Overdue by ${fmtDuration(m)}`;
}
