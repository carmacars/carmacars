import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Card, Table, t } from '@/features/admin/ui';
import { hoursText } from './model';

export type PayShift = { id: string; staff_id: string; name: string; started_at: string; ended_at: string | null; note: string | null; source: string; minutes: number; open: boolean; day: string; locked: boolean; edits: number };
export type PayStaff = { id: string; name: string; active: boolean; rate_cents?: number | null; own_rate?: number | null; minutes: number };
export type Clocked = { staff_id: string; name: string; started_at: string; shift_id: string };
export type Period = { start: string; end: string; label: string; ended: boolean; prev: string; next: string | null };
export type PayData = { today: string; admin: boolean; period: Period; shifts: PayShift[]; clocked_in: Clocked[]; staff: PayStaff[];
  settings: { anchor: string; default_rate_cents: number; overtime_on: boolean; overtime_weekly_hours: number; overtime_bps: number; vacation_pay_bps: number; shift_max_hours: number } };


// Hours of a pay period (0165): who is clocked in, every shift with the office's edits (a reason for each, logged), hours entered
// for someone who forgot to clock, and the period's two-week navigation. Used by Admin > Money > Field pay and Fleet > Field hours.
export function HoursBoard({ data, base, extra = '' }: { data: PayData; base: string; extra?: string }) {
  const R = [base];
  const staff = data.staff.filter((s) => s.active).map((s) => [s.id, s.name] as [string, string]);
  const nav = (date: string) => `${base}?${extra}date=${date}`;
  return (
    <>
      <p className="small" data-testid="period-nav">
        <Link prefetch={false} className="link" href={nav(data.period.prev)}>Earlier period</Link>{' · '}<b>{data.period.label}</b>{data.period.ended ? ' (ended)' : ' (current)'}
        {data.period.next ? <>{' · '}<Link prefetch={false} className="link" href={nav(data.period.next)}>Later period</Link></> : null}
      </p>
      <Card title="Clocked in now" testId="clocked-in">
        {data.clocked_in.length ? <Table<Clocked & Record<string, unknown>> rows={data.clocked_in as Array<Clocked & Record<string, unknown>>} rowKey={(r) => r.shift_id} cols={[
          { key: 'name', label: 'Staff member' }, { key: 'started_at', label: 'Since', render: (r) => t(r.started_at) },
          { key: 'act', label: '', render: (r) => <Act ops action="field_shift_edit" payload={{ id: r.shift_id }} label="Clock out for them" testId={`clockout-${r.shift_id}`} refresh={R} done="Clocked out."
            fields={[{ name: 'ended_at', label: 'Ended', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'reason', label: 'Reason', type: 'text', required: true, hint: 'It is written in the log of changes.' }]} /> }]} />
          : <p className="ad-empty">Nobody is clocked in.</p>}
      </Card>
      <Card title="Hours of the period" testId="shifts" aside={<Act ops action="field_shift_add" label="Add hours" variant="primary" testId="shift-add" refresh={R} done="Hours added."
        fields={[{ name: 'staff', label: 'Staff member', type: 'select', required: true, options: staff }, { name: 'started_at', label: 'Started', type: 'datetime', required: true, value: `${data.today}T09:00` },
          { name: 'ended_at', label: 'Ended', type: 'datetime', required: true, value: `${data.today}T17:00` }, { name: 'note', label: 'Note', type: 'text' },
          { name: 'reason', label: 'Reason (for example, forgot to clock)', type: 'text', required: true }]} />}>
        <Table<PayShift & Record<string, unknown>> rows={data.shifts as Array<PayShift & Record<string, unknown>>} empty="No hours in this period." cols={[
          { key: 'name', label: 'Staff member' }, { key: 'started_at', label: 'From', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'To', render: (r) => (r.ended_at ? t(r.ended_at) : <b>still open</b>) },
          { key: 'minutes', label: 'Hours', num: true, render: (r) => hoursText(r.minutes) },
          { key: 'note', label: 'Note', className: 'wrap', render: (r) => <span>{r.note ?? ''}{r.source === 'manual' ? <span className="ad-sub">entered by the office</span> : null}{r.edits > 0 ? <span className="ad-sub">changed {r.edits} time{r.edits === 1 ? '' : 's'}</span> : null}</span> },
          { key: 'act', label: '', render: (r) => r.locked ? <span className="small muted">Pay run approved</span> : (
            <span className="ad-actions">
              <Act ops action="field_shift_edit" payload={{ id: r.id }} label="Change" testId={`shift-edit-${r.id}`} refresh={R} done="Changed. The change is in the log."
                fields={[{ name: 'started_at', label: 'Started', type: 'datetime', required: true, value: r.started_at }, { name: 'ended_at', label: 'Ended', type: 'datetime', value: r.ended_at },
                  { name: 'note', label: 'Note', type: 'text', value: r.note }, { name: 'reason', label: 'Reason for the change', type: 'text', required: true }]} />
              <Act ops action="field_shift_void" payload={{ id: r.id }} label="Remove" testId={`shift-void-${r.id}`} refresh={R} done="Removed. It stays in the log."
                fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} /></span>) }]} />
      </Card>
    </>
  );
}

