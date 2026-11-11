// Staff schedules (migration 1502): the words for a schedule's days and hours, shared by the Admin and staff pages.
//   node --test --experimental-strip-types src/features/staff-schedule/model.test.ts   (npm run test:unit)
export interface Schedule { id: string; function: string; user_id: string | null; weekdays: number[]; month_days: number[]; start: string; end: string;
  extra_days_per_week: number; starts_on: string | null; note: string | null; name?: string }
export interface DayStatus { scheduled: boolean; starts_at?: string; ends_at?: string; first_in?: string | null; minutes?: number; late_minutes?: number | null; late?: boolean; absent?: boolean }
export interface BoardRow { user_id: string; name: string; functions: string[]; today: DayStatus; on_shift: boolean; clocked_in: boolean }

const DAY: readonly string[] = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const ord = (n: number) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : (['th', 'st', 'nd', 'rd'][n % 10] ?? 'th')}`;
/** "8:00 am" from "08:00" */
export function clockWords(hhmm: string): string {
  const [h = 0, m = 0] = hhmm.split(':').map(Number);
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`;
}
/** "6 days a week (Tuesday off)", "Monday, Wednesday and Friday, plus the 10th and the 15th" */
export function daysWords(s: Pick<Schedule, 'weekdays' | 'month_days'>): string {
  const wd = [...s.weekdays].sort((a, b) => a - b);
  const list = (xs: string[]) => (xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`);
  let w = '';
  if (wd.length === 7) w = 'Every day';
  else if (wd.length >= 5) w = `${wd.length} days a week (${list([1, 2, 3, 4, 5, 6, 7].filter((d) => !wd.includes(d)).map((d) => DAY[d] ?? ''))} off)`;
  else if (wd.length) w = list(wd.map((d) => DAY[d] ?? ''));
  const md = [...s.month_days].sort((a, b) => a - b).map((d) => `the ${ord(d)}`);
  if (!md.length) return w;
  return w ? `${w}, plus ${list(md)} of each month` : `${list(md)} of each month`;
}
export function scheduleWords(s: Schedule): string {
  const extra = s.extra_days_per_week > 0 ? `; up to ${s.extra_days_per_week} extra day${s.extra_days_per_week > 1 ? 's' : ''} a week with overflow work` : '';
  return `${daysWords(s)}, ${clockWords(s.start)} to ${clockWords(s.end)} Toronto${extra}`;
}
/** the duty board's word for a person today */
export function dutyWords(r: BoardRow): string {
  const t = r.today;
  if (!t.scheduled) return r.clocked_in ? 'Clocked in (extra day)' : 'Not scheduled today';
  if (t.absent) return 'Absent';
  if (r.clocked_in) return t.late ? `Working, started ${t.late_minutes ?? 0} min late` : 'Working';
  if (t.late) return `Late ${t.late_minutes ?? 0} min, not clocked in`;
  return t.first_in ? 'Done for now' : 'Not started yet';
}
