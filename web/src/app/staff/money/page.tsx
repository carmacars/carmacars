import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { tabOf } from '@/features/admin/hubs';
import { PaymentsView } from '@/features/money/PaymentsView';
import { ledgerFilters, torontoToday, type Ledger } from '@/features/money/ledger';
import { ToHandle } from './ToHandle';
import { Reconciliation } from './Reconciliation';
import { Deposits, Payments, Refunds } from './Lists';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Money', path: '/staff/money', noindex: true, description: 'Money to handle, payments by day, every payment, refunds, deposits and the processor payouts.' });

const TABS = ['handle', 'day', 'payments', 'refunds', 'deposits', 'reconciliation'] as const;

// Finance > Money (r27 consolidation: Admin's merged Payments for the finance role, the owner: "every Admin upgrade
// reaches each staff role's portal"): To handle, By day (with the quick ranges), All payments, Refunds, Deposits and
// Reconciliation, the tab row of the page group (features/admin/hubs.ts STAFF_HUBS). /staff/payments and
// /staff/reconciliation redirect to their tabs. Finance only; the database checks every read and action.
export default async function Money({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [ctx, sp] = await Promise.all([vaPage('/staff/money', ['finance']), searchParams]);
  const tab = tabOf(TABS, sp.tab);
  const one = (k: string) => (typeof sp[k] === 'string' ? (sp[k] as string) : undefined);
  if (tab === 'day') {
    const l = await door<Ledger>(ctx.user.id, 'ops_read', 'payments_ledger', { ...ledgerFilters(sp, torontoToday()), _va: ctx.fn }, ctx.aal);
    return <PaymentsView l={l} base="/staff/money?tab=day" bookingBase="/staff/bookings" />;
  }
  if (tab === 'payments') return <Payments ctx={ctx} status={one('status')} />;
  if (tab === 'refunds') return <Refunds ctx={ctx} status={one('status')} />;
  if (tab === 'deposits') return <Deposits ctx={ctx} />;
  if (tab === 'reconciliation') return <Reconciliation ctx={ctx} sp={{ month: one('month') }} />;
  return <ToHandle ctx={ctx} />;
}
