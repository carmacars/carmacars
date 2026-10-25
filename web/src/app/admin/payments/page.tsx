import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PaymentsView } from '@/features/money/PaymentsView';
import { ledgerFilters, torontoToday, type Ledger } from '@/features/money/ledger';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payments', path: '/admin/payments', noindex: true, description: 'Payments and refunds by day and method, and the cash drawer.' });

// Payments (0144): one view of the money for a day or a range, the same as Finance's.
export default async function AdminPayments({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/payments'), searchParams]);
  const f = ledgerFilters(sp, torontoToday());
  const l = await door<Ledger>(user.id, 'ops_read', 'payments_ledger', f);
  return <PaymentsView l={l} base="/admin/payments" bookingBase="/admin/bookings" />;
}
