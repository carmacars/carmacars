import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, PageHead, Table, Tabs, d, t } from '@/features/admin/ui';
import { HoursBoard, type PayData } from '@/features/field-pay/HoursBoard';
import { PAY_METHODS, hoursText, methodWords, overtimeWords } from '@/features/field-pay/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field pay', path: '/admin/money/field-pay', noindex: true, description: 'Field staff hours, the two-week pay run, payments and pay statements.' });

type Line = { id?: string; staff_id: string; name: string; rate_cents: number; minutes_total: number; minutes_overtime: number; wage_cents: number; overtime_cents: number; commission_cents: number;
  vacation_cents: number; gross_cents: number; status: string; statement_number?: string | null; paid_on?: string | null; method?: string | null; reference?: string | null; emailed_at?: string | null };
type Data = PayData & { run: { id: string; status: string; approved_at: string | null; approved_by: string | null } | null; lines: Line[]; totals: { gross_cents: number; minutes: number };
  periods: Array<{ start: string; label: string; run_status: string | null; gross_cents: number | null }> };

// Admin > Money > Field pay (migration 0165): the two-week pay run (hours times the person's rate, plus the staff commissions
// approved by the period's end), the hours behind it, and each person's hourly rate. Nothing is paid automatically: approve the
// run, then record how each person was paid. Vacation pay and statutory deductions are not computed unless switched on / by the accountant.
export default async function FieldPay({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/money/field-pay'), searchParams]);
  const tab = sp.tab ?? 'run';
  const base = '/admin/money/field-pay';
  const data = await door<Data>(user.id, 'ops_read', 'field_pay', sp.date ? { date: sp.date } : {});
  const q = (x: string) => `${base}?tab=${x}${sp.date ? `&date=${sp.date}` : ''}`;
  const tabs = <Tabs current={q(tab)} items={[[q('run'), 'Pay run'], [q('hours'), 'Hours'], [q('rates'), 'Hourly rates']]} />;
  const s = data.settings;
  const R = [base];
  const run = data.run;
  if (tab === 'hours') return (<><PageHead title="Field hours" kicker={data.period.label} />{tabs}<HoursBoard data={data} base={base} extra="tab=hours&" /></>);
  if (tab === 'rates') return (<><PageHead title="Hourly rates" kicker={`The default is ${$(s.default_rate_cents)} an hour`} />{tabs}
    <p className="small muted">Each field staff member is paid the default rate unless they have their own. The rate of a pay run is the rate when the run was started. The default, the overtime rule and vacation pay are in <Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link>. {overtimeWords(s.overtime_on, s.overtime_weekly_hours, s.overtime_bps)}</p>
    <Table<Record<string, unknown>> testId="rates" rows={data.staff as unknown as Array<Record<string, unknown>>} empty="No field staff." cols={[
      { key: 'name', label: 'Staff member' }, { key: 'rate_cents', label: 'Hourly rate', num: true, render: (r) => $(r.rate_cents) },
      { key: 'own_rate', label: 'Own rate', render: (r) => (r.own_rate ? 'Yes' : 'Default') },
      { key: 'act', label: '', render: (r) => <Act ops action="field_pay_rate_set" payload={{ staff: r.id }} label="Set the rate" testId={`rate-${String(r.id)}`} refresh={R} done="Rate set. It is in the log."
        fields={[{ name: 'rate_cents', label: 'Hourly rate', type: 'money', required: true, value: r.rate_cents }, { name: 'reason', label: 'Why', type: 'text', required: true }]} /> }]} /></>);
  return (<>
    <PageHead title="Field pay" kicker={`${data.period.label}${data.period.ended ? ' (ended)' : ' (in progress)'}`} />{tabs}
    <p className="small muted" data-testid="pay-note">Paid every two weeks: hours times the hourly rate, plus the staff commissions and referral fees approved by the end of the period. {overtimeWords(s.overtime_on, s.overtime_weekly_hours, s.overtime_bps)}{s.vacation_pay_bps > 0 ? ` Vacation pay of ${s.vacation_pay_bps / 100}% is added.` : ' Vacation pay is not added.'} No income tax, CPP or EI is worked out here: that is for your accountant.</p>
    <p className="small" data-testid="period-nav"><Link prefetch={false} className="link" href={`${base}?date=${data.period.prev}`}>Earlier period</Link>{data.period.next ? <>{' · '}<Link prefetch={false} className="link" href={`${base}?date=${data.period.next}`}>Later period</Link></> : null}</p>
    <Card title={run ? `Pay run: ${run.status}` : 'Pay run not started'} testId="pay-run" aside={<span className="ad-actions">
      {!run && <Act ops action="field_pay_run_start" payload={{ date: data.period.start }} label="Start the pay run" variant="primary" testId="run-start" refresh={R} done="Pay run started." />}
      {run?.status === 'draft' && <Act ops action="field_pay_run_refresh" payload={{ run_id: run.id }} label="Refresh the figures" testId="run-refresh" refresh={R} done="Figures refreshed." />}
      {run?.status === 'draft' && <Act ops action="field_pay_run_approve" payload={{ run_id: run.id }} label="Approve" variant="primary" testId="run-approve" refresh={R} done="Approved. The period's hours are locked and the statements are numbered."
        confirm={`Approve the pay run of ${data.period.label}: ${$(data.totals.gross_cents)} for ${data.lines.length} people. The hours of the period are locked.`} />}
      {run && run.status !== 'void' && run.status !== 'paid' && <Act ops action="field_pay_run_void" payload={{ run_id: run.id }} label="Withdraw" variant="danger" testId="run-void" refresh={R} done="Withdrawn."
        fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} />}
      {run && <a className="btn btn--ghost btn--sm" href={`${base}/csv?run=${run.id}`} data-testid="run-csv">CSV</a>}</span>}>
      {run?.approved_at && <p className="small muted">Approved {t(run.approved_at)}{run.approved_by ? ` by ${run.approved_by}` : ''}.</p>}
      <Table<Line & Record<string, unknown>> testId="pay-lines" rows={data.lines as Array<Line & Record<string, unknown>>} rowKey={(r) => String(r.id ?? r.staff_id)} empty="No hours or commissions in this period." cols={[
        { key: 'name', label: 'Staff member' }, { key: 'minutes_total', label: 'Hours', num: true, render: (r) => hoursText(r.minutes_total) }, { key: 'rate_cents', label: 'Rate', num: true, render: (r) => $(r.rate_cents) },
        { key: 'wage_cents', label: 'Wages', num: true, render: (r) => $(Number(r.wage_cents) + Number(r.overtime_cents)) },
        { key: 'commission_cents', label: 'Commissions', num: true, render: (r) => $(r.commission_cents) },
        ...(s.vacation_pay_bps > 0 ? [{ key: 'vacation_cents', label: 'Vacation pay', num: true, render: (r: Line) => $(r.vacation_cents) }] : []),
        { key: 'gross_cents', label: 'Total', num: true, render: (r) => <b>{$(r.gross_cents)}</b> },
        { key: 'status', label: 'Status', className: 'wrap', render: (r) => r.status === 'paid' ? <span><Badge s="paid" /><span className="ad-sub">{d(r.paid_on)}, {methodWords(r.method)}{r.reference ? `, ${r.reference}` : ''}</span></span> : r.status === 'preview' ? 'Not started' : <Badge s="pending_approval">{run?.status === 'draft' ? 'Draft' : 'To pay'}</Badge> },
        { key: 'act', label: '', render: (r) => !r.id || !run || run.status === 'draft' ? null : <span className="ad-actions">
          <a className="btn btn--ghost btn--sm" href={`/files/pay_statement/${r.id}`} data-testid={`statement-${String(r.id)}`}>{r.statement_number ?? 'Statement'}</a>
          {r.status !== 'paid' && <Act ops action="field_pay_line_paid" payload={{ line_id: r.id }} label="Record payment" variant="primary" testId={`pay-${String(r.id)}`} refresh={R} done="Payment recorded. The statement is emailed."
            fields={[{ name: 'method', label: 'How it was paid', type: 'select', required: true, options: PAY_METHODS, value: 'e_transfer' }, { name: 'reference', label: 'Reference (e-Transfer or bank number; not needed for cash)', type: 'text' },
              { name: 'paid_on', label: 'Date paid', type: 'date', value: data.today }, { name: 'note', label: 'Note', type: 'text' }]} />}
          {r.status === 'paid' && <Act ops action="field_pay_line_email" payload={{ line_id: r.id }} label={r.emailed_at ? 'Send again' : 'Email the statement'} testId={`email-${String(r.id)}`} refresh={R} done="Emailed." />}</span> }]} />
      <p className="small" data-testid="pay-total">Total: <b>{$(data.totals.gross_cents)}</b> for {hoursText(data.totals.minutes)} of work.</p>
    </Card>
    <Card title="Pay periods" testId="pay-periods"><Table<Record<string, unknown>> rows={data.periods as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.start)} cols={[
      { key: 'label', label: 'Period', render: (r) => <Link prefetch={false} className="link" href={`${base}?date=${String(r.start)}`}>{String(r.label)}</Link> },
      { key: 'run_status', label: 'Pay run', render: (r) => (r.run_status ? <Badge s={String(r.run_status)} /> : 'Not started') }, { key: 'gross_cents', label: 'Total', num: true, render: (r) => (r.gross_cents === null ? '' : $(r.gross_cents)) }]} /></Card>
  </>);
}
