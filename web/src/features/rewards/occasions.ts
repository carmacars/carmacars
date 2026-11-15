// r48 (migrations 3000, 3001): the words of the birthday and holiday rewards and the Rewards emails. Pure, no imports:
// the Admin and renter pages and `node --test` read it.

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const NTH = ['1st', '2nd', '3rd', '4th', '5th'];
const DAYS_IN = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

export interface HolidayRule { kind: 'fixed' | 'nth_weekday' | 'weekday_before' | 'easter'; month: number | null; day: number | null; isodow: number | null; nth: number | null; offset_days: number }

export const monthName = (m: number) => MONTHS[m - 1] ?? '';
export const MONTH_OPTIONS: Array<[string, string]> = MONTHS.map((m, i) => [String(i + 1), m]);
export const WEEKDAY_OPTIONS: Array<[string, string]> = DAYS.map((d, i) => [String(i + 1), d]);

/** "December 25", "3rd Monday of February", "Monday before May 25", "Easter Sunday, 2 days before" */
export function holidayRule(h: HolidayRule): string {
  const off = h.offset_days ? `, ${Math.abs(h.offset_days)} ${Math.abs(h.offset_days) === 1 ? 'day' : 'days'} ${h.offset_days < 0 ? 'before' : 'after'}` : '';
  if (h.kind === 'easter') return `Easter Sunday${off}`;
  const m = monthName(h.month ?? 0);
  if (h.kind === 'fixed') return `${m} ${h.day ?? ''}${off}`;
  const d = DAYS[(h.isodow ?? 1) - 1];
  if (h.kind === 'nth_weekday') return `${NTH[(h.nth ?? 1) - 1]} ${d} of ${m}${off}`;
  return `${d} before ${m} ${h.day ?? ''}${off}`;
}

/** basis points as the page shows them: 1000 is "10%", 1250 is "12.5%"; 0 is "Off" */
export function pct(bps: number | null | undefined): string {
  const n = Number(bps ?? 0);
  if (!n) return 'Off';
  return `${Number((n / 100).toFixed(2))}%`;
}

/** The birthday the renter types: a month and a day, the year optional. Null when it is fine, else the problem. */
export function birthdayProblem(month: string, day: string, year: string, thisYear = new Date().getFullYear()): string | null {
  if (!month && !day && !year) return null;
  const m = Number(month), d = Number(day);
  if (!Number.isInteger(m) || m < 1 || m > 12) return 'Choose the month.';
  const most = DAYS_IN[m - 1] ?? 31;
  if (!Number.isInteger(d) || d < 1 || d > most) return `${monthName(m)} has days 1 to ${most}.`;
  if (year) {
    const y = Number(year);
    if (!Number.isInteger(y) || y < 1900 || y > thisYear - 16) return 'Check the year, or leave it empty.';
    if (m === 2 && d === 29 && !(y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0))) return `${y} has no February 29.`;
  }
  return null;
}

/** "Transactional" or "Marketing (unsubscribe link)" */
export const noticeKind = (category: string) => (category === 'marketing' ? 'Marketing, with an unsubscribe link' : 'About their account');
