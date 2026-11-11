import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Table, d, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { PAY_METHODS, biweekly, hoursText, methodWords, payMoney } from '@/features/field-pay/model';
import { STAFF_FN_LABEL, type StaffFn } from '@/features/staff/nav';

// Payroll (migration 1503): one run every two weeks for the salaried office staff (monthly x 12 / 26) and the field staff
// (hours x rate). Finance prepares it (start, refresh, adjustments, Send for approval); only an Admin approves it and records
// the payments, one by one or all at once. Nothing is paid by itself. The same component on Admin > Money > Payroll and on
// Finance's Payroll page; the Admin-only buttons are shown to an Admin only (the database refuses them to anyone else).
export type PayLine = { id: string; staff_id: string; name: string; kind: 'salary' | 'hourly'; currency: string; rate_cents: number; minutes_total: number; clock_minutes: number;
  wage_cents: number; salary_cents: number; monthly_salary_cents: number | null; salary_days: number | null; commission_cents: number; vacation_cents: number; adjustment_cents: number;
  adjustment_note: string | null; gross_cents: number; status: string; statement_number: string | null; paid_on: string | null; method: string | null; reference: string | null; emailed_at: string | null };
type View = { today: string; admin: boolean; period: { start: string; end: string; label: string; ended: boolean; prev: string; next: string | null };
  run: { id: string; status: string; approved_at: string | null; prepared_at: string | null; approved_by: string | null; prepared_by: string | null } | null;
  lines: PayLine[]; totals: Array<{ currency: string; gross_cents: number; people: number }>;
  adjustments: Array<{ id: string; staff_id: string; name: string; amount_cents: number; reason: string; by: string; at: string }>;
  salaried: Array<{ id: string; name: string; functions: string[]; monthly_cents: number | null; own: boolean; currency: string; biweekly_cents: number | null }>;
  staff: Array<{ id: string; name: string }>; periods: Array<{ start: string; label: string; run_status: string | null; prepared: boolean | null }> };

const fnLabel = (f: string) => STAFF_FN_LABEL[f as StaffFn] ?? f;
const lineWhat = (l: PayLine) => (l.kind === 'salary'
  ? `Salary${l.monthly_salary_cents ? ` (${payMoney(l.monthly_salary_cents, l.currency)} a month x 12 / 26${l.salary_days !== null && l.salary_days < 14 ? `, ${l.salary_days} of 14 days` : ''})` : ''}`
  : `${hoursText(l.minutes_total)} at ${payMoney(l.rate_cents, l.currency)}`);

export async function Payroll({ userId, aal, base, date }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: string; date?: string }) {
  const v = await door<View>(userId, 'ops_read', 'payroll', date ? { date } : {}, aal);
  const R = [base];
  const run = v.run;
  const draft = run?.status === 'draft';
  const totals = v.totals.length ? v.totals.map((x) => `${payMoney(x.gross_cents, x.currency)} (${x.people} ${x.people === 1 ? 'person' : 'people'})`).join(' and ') : 'nothing yet';
  return (<>
    <p className="small" data-testid="period-nav"><b>{v.period.label}</b>{v.period.ended ? ' (ended)' : ' (in progress)'} · <Link prefetch={false} className="link" href={`${base}?date=${v.period.prev}`}>Earlier period</Link>
      {v.period.next ? <>{' · '}<Link prefetch={false} className="link" href={`${base}?date=${v.period.next}`}>Later period</Link></> : null}</p>
    <Card title={run ? `Payroll: ${run.status === 'draft' ? (run.prepared_at ? 'waiting for an Admin' : 'draft') : run.status}` : 'Payroll not started'} testId="pay-run" aside={<span className="ad-actions">
      {!run && <Act ops action="field_pay_run_start" payload={{ date: v.period.start }} label="Start the payroll" variant="primary" testId="run-start" refresh={R} done="Payroll started." />}
      {draft && <Act ops action="field_pay_run_refresh" payload={{ run_id: run!.id }} label="Refresh the figures" testId="run-refresh" refresh={R} done="Figures refreshed." />}
      {draft && <Act ops action="payroll_adjust" payload={{ run_id: run!.id }} label="Add a bonus or deduction" testId="run-adjust" refresh={R} done="Added to the line."
        fields={[{ name: 'staff', label: 'Staff member', type: 'select', required: true, options: v.staff.map((s) => [s.id, s.name] as [string, string]) },
          { name: 'amount_cents', label: 'Amount (a deduction is negative), in the line\'s currency', type: 'money', required: true }, { name: 'reason', label: 'Reason (on the pay stub)', type: 'text', required: true }]} />}
      {draft && !run!.prepared_at && v.period.ended && <Act ops action="payroll_submit" payload={{ run_id: run!.id }} label="Send for approval" variant={v.admin ? 'ghost' : 'primary'} testId="run-submit" refresh={R}
        done="Sent: the Admins are asked to approve it." confirm={`Send the payroll of ${v.period.label} for approval: ${totals}.`} />}
      {v.admin && draft && <Act ops action="field_pay_run_approve" payload={{ run_id: run!.id }} label="Approve" variant="primary" testId="run-approve" refresh={R} done="Approved. The stubs are numbered and in each portal."
        confirm={`Approve the payroll of ${v.period.label}: ${totals}. Field hours of the period are locked.`} />}
      {v.admin && run?.status === 'approved' && <Act ops action="payroll_pay_all" payload={{ run_id: run.id }} label="Record all payments" variant="primary" testId="run-pay-all" refresh={R}
        done="Payments recorded. Each stub is emailed." fields={[{ name: 'method', label: 'How they were paid', type: 'select', required: true, options: PAY_METHODS, value: 'e_transfer' },
          { name: 'reference', label: 'Reference (each stub number is added to it; not needed for cash)', type: 'text' }, { name: 'paid_on', label: 'Date paid', type: 'date', value: v.today }]} />}
      {v.admin && run && run.status !== 'void' && run.status !== 'paid' && <Act ops action="field_pay_run_void" payload={{ run_id: run.id }} label="Withdraw" variant="danger" testId="run-void" refresh={R} done="Withdrawn."
        fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} />}</span>}>
      {run?.prepared_at && <p className="small muted" data-testid="run-prepared">Sent for approval {t(run.prepared_at)}{run.prepared_by ? ` by ${run.prepared_by}` : ''}.</p>}
      {run?.approved_at && <p className="small muted">Approved {t(run.approved_at)}{run.approved_by ? ` by ${run.approved_by}` : ''}.</p>}
      <Table<PayLine & Record<string, unknown>> testId="pay-lines" rows={v.lines as Array<PayLine & Record<string, unknown>>} rowKey={(r) => r.id} empty={run ? 'Nobody to pay in this period.' : 'Start the payroll to see each person\'s pay.'} cols={[
        { key: 'name', label: 'Staff member' }, { key: 'what', label: 'Pay', className: 'wrap', render: (r) => lineWhat(r) },
        { key: 'hours', label: 'Hours', num: true, render: (r) => hoursText(r.kind === 'salary' ? r.clock_minutes : r.minutes_total) },
        { key: 'commission_cents', label: 'Commissions', num: true, render: (r) => (r.commission_cents ? payMoney(r.commission_cents, r.currency) : '') },
        { key: 'adjustment_cents', label: 'Bonus or deduction', num: true, render: (r) => (r.adjustment_cents ? <span title={r.adjustment_note ?? ''}>{payMoney(r.adjustment_cents, r.currency)}</span> : '') },
        { key: 'gross_cents', label: 'Total', num: true, render: (r) => <b>{payMoney(r.gross_cents, r.currency)}</b> },
        { key: 'status', label: 'Status', className: 'wrap', render: (r) => r.status === 'paid' ? <span><Badge s="paid" /><span className="ad-sub">{d(r.paid_on)}, {methodWords(r.method)}{r.reference ? `, ${r.reference}` : ''}</span></span>
          : <Badge s="pending_approval">{draft ? 'Draft' : 'To pay'}</Badge> },
        { key: 'act', label: '', render: (r) => !run || draft ? null : <span className="ad-actions">
          <a className="btn btn--ghost btn--sm" href={`/files/pay_statement/${r.id}`} data-testid={`statement-${r.id}`}>{r.statement_number ?? 'Stub'}</a>
          {v.admin && r.status !== 'paid' && <Act ops action="field_pay_line_paid" payload={{ line_id: r.id }} label="Record payment" variant="primary" testId={`pay-${r.id}`} refresh={R} done="Payment recorded. The stub is emailed."
            fields={[{ name: 'method', label: 'How it was paid', type: 'select', required: true, options: PAY_METHODS, value: 'e_transfer' }, { name: 'reference', label: 'Reference (e-Transfer or bank number; not needed for cash)', type: 'text' },
              { name: 'paid_on', label: 'Date paid', type: 'date', value: v.today }, { name: 'note', label: 'Note', type: 'text' }]} />}
          {v.admin && r.status === 'paid' && <Act ops action="field_pay_line_email" payload={{ line_id: r.id }} label={r.emailed_at ? 'Send again' : 'Email the stub'} testId={`email-${r.id}`} refresh={R} done="Emailed." />}</span> }]} />
      <p className="small" data-testid="pay-total">Total: <b>{totals}</b>. Amounts are before any deduction for tax; nothing is paid until an Admin records the payment.</p>
      {v.adjustments.length > 0 && <Table<Record<string, unknown>> testId="pay-adjustments" rows={v.adjustments as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.id)} cols={[
        { key: 'name', label: 'Bonus or deduction for' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => payMoney(r.amount_cents, v.lines.find((l) => l.staff_id === r.staff_id)?.currency) },
        { key: 'reason', label: 'Reason', className: 'wrap' }, { key: 'by', label: 'By', render: (r) => `${String(r.by)}, ${t(String(r.at))}` },
        { key: 'act', label: '', render: (r) => (draft ? <Act ops action="payroll_adjust" payload={{ id: r.id, remove: true }} label="Remove" refresh={R} done="Removed." confirm="Remove this bonus or deduction?" /> : null) }]} />}
    </Card>
    <Card title="Salaries" testId="pay-salaries">
      <p className="small muted">Paid every two weeks: the monthly salary x 12 / 26, for the days employed in the period. A person&apos;s own salary replaces their role&apos;s; the role salaries are in <Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link> (va_salary_defaults).</p>
      <Table<Record<string, unknown>> rows={v.salaried as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.id)} empty="No customer service, Fleet or Finance staff yet." cols={[
        { key: 'name', label: 'Staff member' }, { key: 'functions', label: 'Role', render: (r) => (r.functions as string[]).map(fnLabel).join(', ') },
        { key: 'monthly_cents', label: 'A month', num: true, render: (r) => (r.monthly_cents === null ? 'Not set' : `${payMoney(r.monthly_cents, String(r.currency))}${r.own ? '' : ' (role)'}`) },
        { key: 'biweekly_cents', label: 'Every two weeks', num: true, render: (r) => (r.monthly_cents === null ? '' : payMoney(biweekly(Number(r.monthly_cents)), String(r.currency))) },
        ...(v.admin ? [{ key: 'act', label: '', render: (r: Record<string, unknown>) => <Act ops action="payroll_salary_set" payload={{ staff: r.id }} label="Set the salary" testId={`salary-${String(r.id)}`} refresh={R} done="Salary set. It is in the log."
          fields={[{ name: 'monthly_cents', label: 'Monthly salary (empty: the role\'s)', type: 'money', value: r.own ? r.monthly_cents : '' },
            { name: 'currency', label: 'Currency', type: 'select', options: [['USD', 'US dollars'], ['CAD', 'Canadian dollars']], value: r.currency }, { name: 'reason', label: 'Why', type: 'text', required: true }]} /> }] : [])]} />
    </Card>
    <Card title="Pay periods" testId="pay-periods"><Table<Record<string, unknown>> rows={v.periods as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.start)} cols={[
      { key: 'label', label: 'Period', render: (r) => <Link prefetch={false} className="link" href={`${base}?date=${String(r.start)}`}>{String(r.label)}</Link> },
      { key: 'run_status', label: 'Payroll', render: (r) => (r.run_status ? <Badge s={String(r.run_status)} /> : 'Not started') },
      { key: 'prepared', label: 'Sent for approval', render: (r) => (r.prepared ? 'Yes' : '') }]} /></Card>
  </>);
}

type Stubs = { stubs: Array<PayLine & { period_label: string; period_start: string }>; salary: { monthly_cents: number | null; currency: string; biweekly_cents: number | null } | null;
  period: { start: string; end: string; label: string } };

/** A staff member's own pay stubs (every office portal; field staff see theirs on My pay). */
export async function MyPayStubs({ userId, aal }: { userId: string; aal?: 'aal1' | 'aal2' | null }) {
  const s = await door<Stubs>(userId, 'ops_read', 'my_pay_stubs', {}, aal);
  return (
    <Card title="Pay stubs" testId="my-pay-stubs">
      {s.salary?.monthly_cents ? <p className="small">Your salary: {payMoney(s.salary.monthly_cents, s.salary.currency)} a month, paid every two weeks as {payMoney(s.salary.biweekly_cents, s.salary.currency)}. This pay period: {s.period.label}.</p>
        : <p className="small muted">Paid every two weeks. This pay period: {s.period.label}.</p>}
      <Table<Record<string, unknown>> rows={s.stubs as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.id)} empty="Your first stub appears once an Admin approves the payroll of a finished period." cols={[
        { key: 'period_label', label: 'Period' }, { key: 'gross_cents', label: 'Total', num: true, render: (r) => payMoney(r.gross_cents, String(r.currency)) },
        { key: 'status', label: 'Status', render: (r) => (r.status === 'paid' ? `Paid ${d(r.paid_on)}${r.method ? `, ${methodWords(String(r.method))}` : ''}` : 'Approved, to be paid') },
        { key: 'id', label: '', render: (r) => <a className="link" href={`/files/pay_statement/${String(r.id)}`} data-testid={`stub-${String(r.id)}`}>{String(r.statement_number ?? 'PDF')}</a> }]} />
    </Card>
  );
}
