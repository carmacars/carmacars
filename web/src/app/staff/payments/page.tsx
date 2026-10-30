import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PaymentsView } from '@/features/money/PaymentsView';
import { ledgerFilters, torontoToday, type Ledger } from '@/features/money/ledger';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payments', path: '/staff/payments', noindex: true, description: 'Payments and refunds by day and method, and the cash drawer.' });

// Finance's day (0151): every payment of the day or range by method, the cash drawer against the count, the refunds to decide.
export default async function VaPayments({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user, aal, fn }, sp] = await Promise.all([vaPage('/staff/payments', ['finance']), searchParams]);
  const f = ledgerFilters(sp, torontoToday());
  const l = await door<Ledger>(user.id, 'ops_read', 'payments_ledger', { ...f, _va: fn }, aal);
  return <PaymentsView l={l} base="/staff/payments" bookingBase="/staff/bookings" />;
}
