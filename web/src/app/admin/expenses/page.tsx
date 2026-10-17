import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act, SaveForm } from '@/features/admin/Act';
import { $, Card, PageHead, Table, d } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Expenses', path: '/admin/expenses', noindex: true, description: 'Company expenses entered by hand.' });
type R = Record<string, unknown>;

export default async function Expenses() {
  const { list } = await page('/admin/expenses');
  const [{ rows }, cats, vehicles] = await Promise.all([list('company_expenses', { order: 'expense_on', limit: 300 }), list<{ code: string; label: string }>('company_expense_categories', { eq: { is_active: true }, order: 'label', asc: true }), list<{ id: string; plate: string | null; model: string; make: string }>('vehicles', { order: 'make', asc: true, limit: 500 })]);
  return (<>
    <PageHead title="Expenses" kicker="A final month accepts no new or changed expense" />
    <Card title="Enter an expense"><SaveForm table="company_expenses" label="Add the expense" testId="expense-add" fields={[{ name: 'expense_on', label: 'Date', type: 'date', required: true, value: new Date().toISOString().slice(0, 10) }, { name: 'category', label: 'Category', type: 'select', required: true, options: cats.rows.map((c) => [c.code, c.label]) },
      { name: 'description', label: 'Description', required: true }, { name: 'amount_cents', label: 'Amount before HST', type: 'money', required: true }, { name: 'hst_cents', label: 'HST', type: 'money' }, { name: 'vehicle_id', label: 'Vehicle', type: 'select', options: vehicles.rows.map((v) => [v.id, `${v.make} ${v.model} ${v.plate ?? ''}`]) }]} /></Card>
    <Table<R> testId="expenses" rows={rows} empty="No expenses entered this month. Use Add the expense to record one with its receipt." cols={[{ key: 'expense_on', label: 'Date', render: (r) => d(r.expense_on) }, { key: 'category', label: 'Category' }, { key: 'description', label: 'Description', className: 'wrap' }, { key: 'vehicle_name', label: 'Vehicle' },
      { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'hst_cents', label: 'HST', num: true, render: (r) => $(r.hst_cents) },
      { key: 'act', label: '', render: (r) => r.voided_at ? `void: ${String(r.void_reason)}` : <Act action="expense_void" payload={{ id: r.id }} label="Void" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={['/admin/expenses']} /> }]} />
  </>);
}
