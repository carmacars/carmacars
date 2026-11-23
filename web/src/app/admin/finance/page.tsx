import '@/components/portal-ui/portal-ui.css';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { tabOf } from '@/features/admin/hubs';
import { FinancePage } from '@/features/finance/FinancePage';
import type { BankLinesView, Dashboard } from '@/features/finance/model';
import { loadStripeCash } from '@/server/finance';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Finance', path: '/admin/finance', noindex: true, description: 'Cash position, money in and out, HST, receivables and the bank reconciliation.' });
const TABS = ['overview', 'bank'] as const;
const MONTH = /^\d{4}-\d{2}-01$/;

// r49 (3480): Admin > Company > Finance
export default async function AdminFinance({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/finance'), searchParams]);
  const tab = tabOf(TABS, sp.tab);
  const [dash, stripe, lines] = await Promise.all([
    tab === 'overview' ? door<Dashboard>(user.id, 'admin_read', 'finance_dashboard', { month: MONTH.test(sp.month ?? '') ? sp.month : null }) : null,
    tab === 'overview' ? loadStripeCash() : null,
    door<BankLinesView>(user.id, 'admin_read', 'bank_lines', { status: sp.status ?? null, limit: tab === 'bank' ? 300 : 1 })]);
  return <FinancePage tab={tab} dash={dash} stripe={stripe} lines={lines} base="/admin" bookingBase="/admin/bookings" />;
}
