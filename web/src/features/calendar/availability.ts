import { addDays, clock, diffDays, minutesToClock, parse, shortDate, torontoParts } from '@/lib/dates';

// Availability on Toronto wall-clock minutes. A block is [start, end) in "minutes since the epoch
// on the Toronto calendar" (the date's UTC midnight in minutes plus the minutes of the day). The
// database already widened each booking by the turnaround buffer (public_vehicle_calendar).
export type Block = [number, number];

export const at = (iso: string, time = '00:00') => {
  const [h, m] = time.split(':').map(Number);
  return parse(iso).getTime() / 6e4 + h! * 60 + m!;
};

export function blocksFromCalendar(rows: { unavailable_from: string; unavailable_to: string }[]): Block[] {
  return rows.map((r) => {
    const a = torontoParts(r.unavailable_from); const b = torontoParts(r.unavailable_to);
    return [at(a.date) + a.minutes, at(b.date) + b.minutes];
  });
}

export interface DayState { full?: boolean; freeFrom?: number; freeUntil?: number }

export function dayState(iso: string, blocks: Block[]): DayState | null {
  const s = at(iso); const e = s + 1440; let st: DayState | null = null;
  for (const [a, b] of blocks) {
    if (a <= s && b >= e) return { full: true };
    if (a < e && b > s) {
      st = st ?? {};
      if (b < e) st.freeFrom = Math.max(st.freeFrom ?? 0, b - s);
      if (a > s) st.freeUntil = Math.min(st.freeUntil ?? 1440, a - s);
    }
  }
  return st;
}

export const clash = (from: string, tf: string, to: string, tt: string, blocks: Block[]) => {
  const a = at(from, tf); const z = at(to, tt);
  return blocks.some(([s, e]) => a < e && z > s);
};

export const partText = (p: DayState) =>
  p.freeFrom != null && p.freeUntil != null ? `free from ${minutesToClock(p.freeFrom)} to ${minutesToClock(p.freeUntil)}`
    : p.freeFrom != null ? `free from ${minutesToClock(p.freeFrom)}` : `free until ${minutesToClock(p.freeUntil ?? 0)}`;

/** Problems with chosen times: the notice period and the turnaround around other bookings. */
export function timeProblem(o: { name?: string; from: string; tf: string; to: string; tt: string; blocks: Block[]; todayIso: string; nowMinutes: number; noticeMinutes: number; noticeText: string; turnaroundText: string }): string {
  const earliest = at(o.todayIso) + o.nowMinutes + o.noticeMinutes;
  if (at(o.from, o.tf) < earliest) {
    const e = earliest - at(o.from);
    return e < 1440 && e >= 0
      ? `Pickup needs at least ${o.noticeText}’ notice. The earliest on ${shortDate(o.from)} is ${minutesToClock(Math.ceil(e / 30) * 30)}.`
      : `Pickup needs at least ${o.noticeText}’ notice.`;
  }
  if (clash(o.from, o.tf, o.to, o.tt, o.blocks)) {
    const car = o.name ? `The ${o.name}` : 'The car';
    const a = dayState(o.from, o.blocks); const z = dayState(o.to, o.blocks);
    if (a?.freeFrom != null) return `${car} is free from ${minutesToClock(a.freeFrom)} on ${shortDate(o.from)}, ${o.turnaroundText} after the booking before yours. Choose a later pickup time.`;
    if (z?.freeUntil != null) return `${car} has to be back by ${minutesToClock(z.freeUntil)} on ${shortDate(o.to)}, ${o.turnaroundText} before the next booking. Choose an earlier return time.`;
    return `Those times cross another booking of ${o.name ? 'the ' + o.name : 'this car'}.`;
  }
  return '';
}

export const daysBetween = (a: string, b: string) => diffDays(a, b);
export { addDays, clock };
