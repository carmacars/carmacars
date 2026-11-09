import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { tabOf } from '@/features/admin/hubs';
import { PaymentsView } from '@/features/money/PaymentsView';
import { ledgerFilters, torontoToday, type Ledger } from '@/features/money/ledger';
import { ToHandle } from './ToHandle';
import { Reconciliation } from './Reconciliation';
import { Deposits, Payments, Refunds } from './Lists';
import { PartnerInvoices } from '@/features/partner-invoices/PartnerInvoices';
import { ProfitExtras } from '@/features/profit-extras/ProfitExtras';
import { CountdownTable } from '@/features/deposit-review/Countdowns';
import type { Countdowns } from '@/features/deposit-review/model';
import { PageHead } from '@/features/admin/ui';
import { UnlinkedStripe, type Unlinked } from '@/features/money/UnlinkedStripe';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Money', path: '/staff/money', noindex: true, description: 'Money to handle, payments by day, every payment, refunds, deposits and the processor payouts.' });

const TABS = ['handle', 'countdowns', 'day', 'payments', 'refunds', 'deposits', 'reconciliation', 'kickbacks', 'partners', 'stripe'] as const;

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
  // r35 part RR (1010): the time left on each deposit hold, deposit return and plan payment
  if (tab === 'countdowns') {
    const c = await door<Countdowns>(ctx.user.id, 'ops_read', 'finance_countdowns', { sort: one('sort'), _va: ctx.fn }, ctx.aal);
    return <><PageHead title="Countdowns" purpose="Deposit holds expiring, deposits owed back to renters and the next payment of weekly, biweekly and monthly plans. Red within 24 hours or late, amber within 48." />
      <CountdownTable c={c} base="/staff/money?tab=countdowns" bookingBase="/staff/bookings" /></>;
  }
  if (tab === 'payments') return <Payments ctx={ctx} status={one('status')} />;
  if (tab === 'refunds') return <Refunds ctx={ctx} status={one('status')} />;
  if (tab === 'deposits') return <Deposits ctx={ctx} />;
  // 0547: invoices to partners (body shops, tow trucks, storage) and the money they send
  // r29 (0581): kickbacks and repair costs for the business, by owner and by car
  if (tab === 'kickbacks') return <ProfitExtras userId={ctx.user.id} aal={ctx.aal} level="business" sp={Object.fromEntries(['from', 'to'].map((k) => [k, one(k)]))} base="/staff/money?tab=kickbacks" carLink={(v) => `/staff/vehicles/${v}`} />;
  if (tab === 'partners') return <PartnerInvoices userId={ctx.user.id} aal={ctx.aal} base="/staff/money?tab=partners" sp={Object.fromEntries(['invoice', 'claim', 'partner'].map((k) => [k, one(k)]))} />;
  if (tab === 'reconciliation') return <Reconciliation ctx={ctx} sp={{ month: one('month') }} />;
  // r35 (1081): the nightly list of Stripe payments no booking knows (linking is an Admin's, on the booking)
  if (tab === 'stripe') {
    const all = one('all') === '1';
    const u = await door<Unlinked>(ctx.user.id, 'ops_read', 'stripe_unlinked', { dismissed: all, _va: ctx.fn }, ctx.aal);
    return <UnlinkedStripe u={u} all={all} base="/staff/money?tab=stripe" bookingHref={(n) => `/staff/bookings/${encodeURIComponent(n)}?tab=money`} />;
  }
  return <ToHandle ctx={ctx} />;
}
