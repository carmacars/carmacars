import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { $, PageHead, Table, Tabs } from '@/features/admin/ui';
import { HoursBoard, type PayData } from '@/features/field-pay/HoursBoard';
import { fieldFinance } from '@/server/field-finance';
import { PayIdentityPanel, SpendingPanel } from '@/features/field-portal/FinancePanels';
import { overtimeWords } from '@/features/field-pay/model';
import { Payroll } from '@/features/payroll/Payroll';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payroll', path: '/admin/money/field-pay', noindex: true, description: 'The two-week payroll of the office and field staff, field hours, rates, payments and pay stubs.' });

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
  const tabs = <Tabs current={q(tab)} items={[[q('run'), 'Payroll'], [q('hours'), 'Hours'], [q('rates'), 'Hourly rates'], [q('spending'), 'Spending and pay details']]} />;
  const s = data.settings;
  const R = [base];
  // r35 part X (0930, 0931): money field staff spent, and their pay details
  if (tab === 'spending') { const f = await fieldFinance(user.id); return (<><PageHead title="Field spending and pay details" kicker={data.period.label} />{tabs}<SpendingPanel rows={f.spends} /><PayIdentityPanel rows={f.ids} /></>); }
  if (tab === 'hours') return (<><PageHead title="Field hours" kicker={data.period.label} />{tabs}<HoursBoard data={data} base={base} extra="tab=hours&" /></>);
  if (tab === 'rates') return (<><PageHead title="Hourly rates" kicker={`The default is ${$(s.default_rate_cents)} an hour`} />{tabs}
    <p className="small muted">Each field staff member is paid the default rate unless they have their own. The rate of a pay run is the rate when the run was started. The default, the overtime rule and vacation pay are in <Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link>. {overtimeWords(s.overtime_on, s.overtime_weekly_hours, s.overtime_bps)}</p>
    <Table<Record<string, unknown>> testId="rates" rows={data.staff as unknown as Array<Record<string, unknown>>} empty="No field staff." cols={[
      { key: 'name', label: 'Staff member' }, { key: 'rate_cents', label: 'Hourly rate', num: true, render: (r) => $(r.rate_cents) },
      { key: 'own_rate', label: 'Own rate', render: (r) => (r.own_rate ? 'Yes' : 'Default') },
      { key: 'act', label: '', render: (r) => <Act ops action="field_pay_rate_set" payload={{ staff: r.id }} label="Set the rate" testId={`rate-${String(r.id)}`} refresh={R} done="Rate set. It is in the log."
        fields={[{ name: 'rate_cents', label: 'Hourly rate', type: 'money', required: true, value: r.rate_cents }, { name: 'reason', label: 'Why', type: 'text', required: true }]} /> }]} /></>);
  // r35 part C (1503): the run tab is the payroll of everyone, salaried office staff and field staff
  return (<>
    <PageHead title="Payroll" kicker={`${data.period.label}${data.period.ended ? ' (ended)' : ' (in progress)'}`} />{tabs}
    <p className="small muted" data-testid="pay-note">Every two weeks: the office staff&apos;s monthly salary x 12 / 26, and the field staff&apos;s hours times their rate plus the commissions approved by the end of the period. {overtimeWords(s.overtime_on, s.overtime_weekly_hours, s.overtime_bps)}{s.vacation_pay_bps > 0 ? ` Vacation pay of ${s.vacation_pay_bps / 100}% is added to field pay.` : ''} Finance prepares it and sends it for approval; you approve it and record the payments. No income tax, CPP or EI is worked out here: that is for your accountant.</p>
    <Payroll userId={user.id} base={base} date={sp.date} />
  </>);
}
