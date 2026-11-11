import { Act } from '@/features/admin/Act';
import { Card, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { STAFF_FN_LABEL, type StaffFn } from '@/features/staff/nav';
import { dutyWords, scheduleWords, type BoardRow, type Schedule } from './model';

// Staff schedules (migration 1502): the role defaults and each person's own (an Admin changes them), the person's week,
// and today's duty board (scheduled, clocked in, late). The same component on Admin > Staff > Schedules and on every office
// staff member's Schedule page; only an Admin sees the change buttons and everyone's own schedules.
type View = { admin: boolean; today: string; late_grace_minutes: number; defaults: Schedule[]; mine: Array<{ function: string; schedule: Schedule }>;
  my_week: Array<{ day: string; shifts: Array<{ function: string; starts_at: string; ends_at: string }> }>;
  own: Schedule[] | null; staff: Array<{ id: string; name: string; functions: string[] }> | null; board: BoardRow[] };

const fnLabel = (f: string) => STAFF_FN_LABEL[f as StaffFn] ?? f;
const day = (s: string) => new Date(`${s}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' });
const hm = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' });

function fields(s?: Partial<Schedule>) {
  return [
    { name: 'weekdays', label: 'Weekdays (1 Monday to 7 Sunday, e.g. 1,3,5)', type: 'text' as const, value: (s?.weekdays ?? []).join(',') },
    { name: 'month_days', label: 'Days of the month too (e.g. 10,15; empty: none)', type: 'text' as const, value: (s?.month_days ?? []).join(',') },
    { name: 'start', label: 'Start (HH:MM, Toronto)', type: 'text' as const, required: true, value: s?.start ?? '09:00' },
    { name: 'end', label: 'End (HH:MM, Toronto)', type: 'text' as const, required: true, value: s?.end ?? '17:00' },
    { name: 'extra_days_per_week', label: 'Extra days a week with overflow work', type: 'number' as const, min: 0, max: 3, value: s?.extra_days_per_week ?? 0 },
    { name: 'starts_on', label: 'Starts on (empty: already)', type: 'date' as const, value: s?.starts_on ?? '' },
    { name: 'note', label: 'Note (breaks are at the person\'s discretion)', type: 'text' as const, value: s?.note ?? '' }];
}

export async function StaffSchedules({ userId, aal, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: string }) {
  const v = await door<View>(userId, 'ops_read', 'staff_schedules', {}, aal);
  const R = [base];
  return (<>
    {v.mine.length > 0 && <Card title="My schedule" testId="my-schedule">
      <ul className="small">{v.mine.map((m) => <li key={m.function}><b>{fnLabel(m.function)}:</b> {scheduleWords(m.schedule)}{m.schedule.user_id ? ' (your own)' : ''}</li>)}</ul>
      <Table<Record<string, unknown>> testId="my-week" rows={v.my_week as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.day)} cols={[
        { key: 'day', label: 'Day', render: (r) => day(String(r.day)) },
        { key: 'shifts', label: 'Hours', render: (r) => { const s = r.shifts as View['my_week'][number]['shifts']; return s.length ? s.map((x) => `${hm(x.starts_at)} to ${hm(x.ends_at)}`).join(', ') : 'Off'; } }]} />
      <p className="small muted">Clock in when you start and out when you stop. A clock-in more than {v.late_grace_minutes} minutes after the start counts as late. Breaks are at your discretion.</p>
    </Card>}
    <Card title="Today" testId="duty-board">
      <Table<BoardRow & Record<string, unknown>> rows={v.board as Array<BoardRow & Record<string, unknown>>} rowKey={(r) => r.user_id} empty="No office staff yet." cols={[
        { key: 'name', label: 'Staff member' }, { key: 'functions', label: 'Role', render: (r) => r.functions.map(fnLabel).join(', ') },
        { key: 'today', label: 'Scheduled', render: (r) => (r.today.scheduled && r.today.starts_at && r.today.ends_at ? `${hm(r.today.starts_at)} to ${hm(r.today.ends_at)}` : 'Off') },
        { key: 'first_in', label: 'First in', render: (r) => (r.today.first_in ? t(r.today.first_in) : '') },
        { key: 'state', label: 'Now', render: (r) => <span data-testid={`duty-${r.user_id}`}>{dutyWords(r)}</span> }]} />
    </Card>
    <Card title="Role schedules" testId="role-schedules">
      <Table<Schedule & Record<string, unknown>> rows={v.defaults as Array<Schedule & Record<string, unknown>>} rowKey={(r) => r.id} cols={[
        { key: 'function', label: 'Role', render: (r) => fnLabel(r.function) }, { key: 'days', label: 'Schedule', className: 'wrap', render: (r) => scheduleWords(r) },
        { key: 'starts_on', label: 'From', render: (r) => (r.starts_on ? day(r.starts_on) : '') },
        ...(v.admin ? [{ key: 'act', label: '', render: (r: Schedule) => <Act ops action="staff_schedule_save" payload={{ function: r.function }} label="Change" testId={`role-schedule-${r.function}`} refresh={R} done="Schedule saved." fields={fields(r)} /> }] : [])]} />
    </Card>
    {v.admin && v.own && v.staff && <Card title="Own schedules" testId="own-schedules"
      aside={<Act ops action="staff_schedule_save" label="Set someone's own schedule" testId="own-schedule-add" refresh={R} done="Schedule saved."
        fields={[{ name: 'user_id', label: 'Staff member', type: 'select', required: true, options: v.staff.map((s) => [s.id, s.name] as [string, string]) },
          { name: 'function', label: 'Role', type: 'select', required: true, options: [['cs', 'Customer service'], ['fleet', 'Fleet'], ['finance', 'Finance'], ['sales', 'Sales']] }, ...fields()]} />}>
      <p className="small muted">A person&apos;s own schedule replaces the role&apos;s for them only. Remove it and the role&apos;s applies again.</p>
      <Table<Schedule & Record<string, unknown>> rows={v.own as Array<Schedule & Record<string, unknown>>} rowKey={(r) => r.id} empty="Everyone follows their role's schedule." cols={[
        { key: 'name', label: 'Staff member' }, { key: 'function', label: 'Role', render: (r) => fnLabel(r.function) },
        { key: 'days', label: 'Schedule', className: 'wrap', render: (r) => scheduleWords(r) },
        { key: 'act', label: '', render: (r) => <span className="ad-actions">
          <Act ops action="staff_schedule_save" payload={{ function: r.function, user_id: r.user_id }} label="Change" refresh={R} done="Schedule saved." fields={fields(r)} />
          <Act ops action="staff_schedule_clear" payload={{ id: r.id }} label="Remove" refresh={R} done="Removed: the role's schedule applies." confirm="Remove this person's own schedule?" /></span> }]} />
    </Card>}
  </>);
}
