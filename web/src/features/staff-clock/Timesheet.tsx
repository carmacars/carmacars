import { Act } from '@/features/admin/Act';
import { DateInput } from '@/components/DateInput';
import { Card, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { STAFF_FN_LABEL, heldFunctions } from '@/features/staff/nav';
import { hoursWords, type ClockEntry, type ClockState } from './model';

// The hours of customer service, Fleet and Finance (1061). My hours: the person's own entries. The timesheet (Finance and
// Admin): each person's total for the range and their entries; hours added by hand or voided, each with a reason.
type Person = { user_id: string; name: string; functions: string[]; minutes: number; open: boolean; entries: ClockEntry[] };

export async function MyHours({ userId, aal }: { userId: string; aal: 'aal1' | 'aal2' | null }) {
  const s = await door<ClockState>(userId, 'ops_read', 'va_clock', {}, aal);
  return (
    <Card title={`Today ${hoursWords(s.today_minutes)} · this week ${hoursWords(s.week_minutes)}`} testId="my-hours">
      <Table<ClockEntry> rows={s.entries} rowKey={(r) => r.id} empty="No hours yet. Clock in on your home page." cols={[
        { key: 'started_at', label: 'In', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'Out', render: (r) => (r.ended_at ? t(r.ended_at) : 'Still in') },
        { key: 'minutes', label: 'Time', num: true, render: (r) => hoursWords(r.minutes) }, { key: 'source', label: 'How', render: (r) => (r.source === 'manual' ? `Added by Finance: ${r.note ?? ''}` : 'Clock') }]} />
    </Card>
  );
}

export async function Timesheet({ userId, aal, from, to, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; from?: string; to?: string; base: string }) {
  const v = await door<{ from: string; to: string; people: Person[] }>(userId, 'ops_read', 'va_timesheet', { from: from ?? null, to: to ?? null }, aal);
  const refresh = [base];
  return (<>
    <form method="get" className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }} data-testid="timesheet-range">
      <label className="small">From <DateInput className="input" type="date" name="from" defaultValue={v.from} /></label>
      <label className="small">To <DateInput className="input" type="date" name="to" defaultValue={v.to} /></label>
      <button type="submit" className="btn btn--sm btn--ghost">Show</button>
    </form>
    {v.people.map((p) => (
      <Card key={p.user_id} title={`${p.name}: ${hoursWords(p.minutes)}`} testId={`timesheet-${p.user_id}`}
        aside={<Act ops action="va_clock_fix" payload={{ user_id: p.user_id }} label="Add hours" refresh={refresh} done="Added."
          fields={[{ name: 'started_at', label: 'Start', type: 'datetime', required: true }, { name: 'ended_at', label: 'End', type: 'datetime', required: true }, { name: 'reason', label: 'Why they are added by hand', type: 'text', required: true }]} />}>
        <p className="small muted">{heldFunctions(p.functions).map((f) => STAFF_FN_LABEL[f]).join(', ')}{p.open ? ' · clocked in now' : ''}</p>
        <Table<ClockEntry> rows={p.entries} rowKey={(r) => r.id} empty="No hours in this range." cols={[
          { key: 'started_at', label: 'In', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'Out', render: (r) => (r.ended_at ? t(r.ended_at) : 'Still in') },
          { key: 'minutes', label: 'Time', num: true, render: (r) => hoursWords(r.minutes) }, { key: 'source', label: 'How', render: (r) => (r.source === 'manual' ? `By hand: ${r.note ?? ''}` : 'Clock') },
          { key: 'id', label: '', render: (r) => <Act ops action="va_clock_fix" payload={{ id: r.id, void: true }} label="Void" refresh={refresh} done="Voided." fields={[{ name: 'reason', label: 'Why it is wrong', type: 'text', required: true }]} /> }]} />
      </Card>))}
    {!v.people.length && <p className="small muted">No customer service, Fleet or Finance staff yet.</p>}
  </>);
}
