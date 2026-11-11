import { Act } from '@/features/admin/Act';
import { DateInput } from '@/components/DateInput';
import { Card, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { STAFF_FN_LABEL, heldFunctions } from '@/features/staff/nav';
import { breaksWords, hoursWords, type BreakEntry, type BreakSummary, type ClockEntry, type ClockState } from './model';

// The hours of customer service, Fleet and Finance (1061). My hours: the person's own entries. The timesheet (Finance and
// Admin): each person's total for the range and their entries; hours added by hand or voided, each with a reason.
// 1800: each person's days (hours, worked hours, breaks; idle for the Admins only), their breaks (an Admin edits one with the
// reason) and, for the Admins, their idle stretches and their Quo user (a Quo call of that user pauses the tracker).
type Day = { day: string; minutes: number; worked_minutes: number; breaks: BreakSummary; idle?: { count: number; minutes: number } };
type Idle = { id: string; started_at: string; ended_at: string | null; minutes: number; open: boolean };
type Person = { user_id: string; name: string; functions: string[]; minutes: number; open: boolean; entries: ClockEntry[]; days?: Day[]; breaks?: BreakEntry[]; idle?: Idle[]; quo_user_id?: string | null };
const breakRows = (rows: BreakEntry[]) => rows as Array<BreakEntry & Record<string, unknown>>;

export async function MyHours({ userId, aal }: { userId: string; aal: 'aal1' | 'aal2' | null }) {
  const s = await door<ClockState>(userId, 'ops_read', 'va_clock', {}, aal);
  return (
    <Card title={`Today ${hoursWords(s.today_minutes)} · this week ${hoursWords(s.week_minutes)}`} testId="my-hours">
      <Table<ClockEntry> rows={s.entries} rowKey={(r) => r.id} empty="No hours yet. Clock in on your home page." cols={[
        { key: 'started_at', label: 'In', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'Out', render: (r) => (r.ended_at ? t(r.ended_at) : 'Still in') },
        { key: 'minutes', label: 'Time', num: true, render: (r) => hoursWords(r.minutes) }, { key: 'source', label: 'How', render: (r) => (r.source === 'manual' ? `Added by Finance: ${r.note ?? ''}` : 'Clock') }]} />
      <h3 className="small">Breaks (the last two weeks){s.settings && !s.settings.breaks_paid ? ': unpaid, they come off your counted hours' : ''}</h3>
      <Table<BreakEntry & Record<string, unknown>> testId="my-breaks" rows={breakRows(s.breaks ?? [])} rowKey={(r) => r.id} empty="No breaks yet." cols={[
        { key: 'started_at', label: 'Start', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'End', render: (r) => (r.ended_at ? t(r.ended_at) : 'On it now') },
        { key: 'minutes', label: 'Time', num: true, render: (r) => hoursWords(r.minutes) }, { key: 'reason', label: 'Reason', render: (r) => r.reason ?? '' },
        { key: 'edit_reason', label: 'Changed by an Admin', render: (r) => r.edit_reason ?? '' }]} />
    </Card>
  );
}

export async function Timesheet({ userId, aal, from, to, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; from?: string; to?: string; base: string }) {
  const v = await door<{ from: string; to: string; people: Person[]; admin?: boolean; breaks_paid?: boolean; idle_alert_minutes?: number }>(userId, 'ops_read', 'va_timesheet', { from: from ?? null, to: to ?? null }, aal);
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
        <h3 className="small">By day{v.breaks_paid === false ? ' (breaks unpaid: worked = clocked less breaks)' : ''}</h3>
        <Table<Day & Record<string, unknown>> testId={`timesheet-days-${p.user_id}`} rows={(p.days ?? []) as Array<Day & Record<string, unknown>>} rowKey={(r) => r.day} empty="No days in this range." cols={[
          { key: 'day', label: 'Day' }, { key: 'minutes', label: 'Clocked', num: true, render: (r) => hoursWords(r.minutes) },
          { key: 'worked_minutes', label: 'Worked', num: true, render: (r) => hoursWords(r.worked_minutes) },
          { key: 'breaks', label: 'Breaks', className: 'wrap', render: (r) => breaksWords(r.breaks) },
          ...(v.admin ? [{ key: 'idle', label: 'Idle time', num: true, render: (r: Day) => (r.idle && r.idle.count ? `${hoursWords(r.idle.minutes)} (${r.idle.count})` : 'None') }] : [])]} />
        {(p.breaks ?? []).length > 0 && <Table<BreakEntry & Record<string, unknown>> testId={`timesheet-breaks-${p.user_id}`} rows={breakRows(p.breaks ?? [])} rowKey={(r) => r.id} cols={[
          { key: 'started_at', label: 'Break', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'End', render: (r) => (r.ended_at ? t(r.ended_at) : 'Still on it') },
          { key: 'minutes', label: 'Time', num: true, render: (r) => hoursWords(r.minutes) },
          { key: 'reason', label: 'Reason', className: 'wrap', render: (r) => [r.reason, r.edit_reason ? `Changed: ${r.edit_reason}` : null].filter(Boolean).join(' · ') },
          ...(v.admin ? [{ key: 'id', label: '', render: (r: BreakEntry) => <span className="ad-actions">
            <Act ops action="va_break_edit" payload={{ id: r.id }} label="Edit" refresh={refresh} done="Break changed." testId={`break-edit-${r.id}`}
              fields={[{ name: 'started_at', label: 'Start', type: 'datetime', required: true, value: r.started_at }, { name: 'ended_at', label: 'End', type: 'datetime', required: true, value: r.ended_at ?? undefined },
                { name: 'reason', label: 'Why it is changed', type: 'text', required: true }]} />
            <Act ops action="va_break_edit" payload={{ id: r.id, void: true }} label="Remove" refresh={refresh} done="Break removed." fields={[{ name: 'reason', label: 'Why it is removed', type: 'text', required: true }]} /></span> }] : [])]} />}
        {v.admin && (p.idle ?? []).length > 0 && <Table<Idle & Record<string, unknown>> testId={`timesheet-idle-${p.user_id}`} rows={(p.idle ?? []) as Array<Idle & Record<string, unknown>>} rowKey={(r) => r.id} cols={[
          { key: 'started_at', label: 'Inactive from', render: (r) => t(r.started_at) }, { key: 'ended_at', label: 'Back at', render: (r) => (r.ended_at ? t(r.ended_at) : 'Still inactive') },
          { key: 'minutes', label: 'Idle', num: true, render: (r) => hoursWords(r.minutes) }]} />}
        {/* an <Act> holds a dialog and a form: in a <div>, never a <p> (a <p> around it breaks hydration, React #418) */}
        {v.admin && <div className="small muted">Quo user: {p.quo_user_id ?? 'not set (their Quo calls do not pause the inactivity tracker)'}{' '}
          <Act ops action="staff_quo_user_set" payload={{ user_id: p.user_id }} label="Set Quo user" variant="quiet" refresh={refresh} done="Saved."
            fields={[{ name: 'quo_user_id', label: 'Quo user id (US…, empty: none)', type: 'text', value: p.quo_user_id ?? '' }]} /></div>}
      </Card>))}
    {!v.people.length && <p className="small muted">No customer service, Fleet or Finance staff yet.</p>}
  </>);
}
