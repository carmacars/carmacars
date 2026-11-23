import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { tabOf } from '@/features/admin/hubs';
import { FinancePage } from '@/features/finance/FinancePage';
import type { BankLinesView, Dashboard } from '@/features/finance/model';
import { loadStripeCash } from '@/server/finance';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Finance', path: '/staff/finance', noindex: true, description: 'Cash position, money in and out, HST, receivables and the bank reconciliation.' });
const TABS = ['overview', 'bank'] as const;
const MONTH = /^\d{4}-\d{2}-01$/;

// r49 (3480): Finance > Money > Finance, Admin's Finance page for the Finance role (Finance only; the database checks each read)
export default async function StaffFinance({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [ctx, sp] = await Promise.all([vaPage('/staff/finance', ['finance']), searchParams]);
  const one = (k: string) => (typeof sp[k] === 'string' ? (sp[k] as string) : undefined);
  const tab = tabOf(TABS, sp.tab);
  const [dash, stripe, lines] = await Promise.all([
    tab === 'overview' ? ctx.read<Dashboard>('finance_dashboard', { month: MONTH.test(one('month') ?? '') ? one('month') : null }) : null,
    tab === 'overview' ? loadStripeCash() : null,
    ctx.read<BankLinesView>('bank_lines', { status: one('status') ?? null, limit: tab === 'bank' ? 300 : 1 })]);
  return <FinancePage tab={tab} dash={dash} stripe={stripe} lines={lines} base="/staff" bookingBase="/staff/bookings" />;
}
