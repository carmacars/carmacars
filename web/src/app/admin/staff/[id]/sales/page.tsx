import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { PageHead, bookingHref, label } from '@/features/admin/ui';
import { SalesBoard, type StaffSales } from '@/features/va/SalesBoard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sales', path: '/admin/staff', noindex: true, description: 'A staff member\'s quotes, offers, bookings and booked revenue.' });

// Admin > People > Staff > a staff member > Sales (migration 0057): the same board as the assistant's My sales, with
// every booking linked and the credit of each deal reassignable (with a reason, kept in the booking's history).
export default async function StaffSalesPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const base = `/admin/staff/${id}/sales`;
  const { read } = await page(base);
  const [s, options] = await Promise.all([
    read<StaffSales | null>('staff_sales', { staff: id, period: sp.period === 'month' ? 'month' : 'week' }).catch(() => null),
    read<Array<{ id: string; name: string; function: string }>>('sales_options').catch(() => [])]);
  if (!s) notFound();
  const opts: Array<[string, string]> = [['', 'Choose who'], ...options.map((o) => [o.id, `${o.name} (${label(o.function)})`] as [string, string]), ['none', 'Nobody']];
  return (
    <>
      <PageHead title={`Sales: ${s.staff.name}`} kicker={<><Link prefetch={false} className="link" href="/admin/settings/staff">Staff</Link> · {s.staff.admin && !s.staff.function ? 'Admin' : label(s.staff.function)}</>}>
        {s.staff.function && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/staff/${id}/scorecard`}>Scorecard</Link>}
      </PageHead>
      <SalesBoard s={s} base={base} sp={sp} own={false} bookingHref={(x) => bookingHref(x.booking_number)}
        dealAction={(x) => (x.credited ? <Act action="sales_reassign" payload={{ booking: x.booking_number }} label="Reassign" testId={`reassign-${x.booking_number}`} refresh={[base]} done="Reassigned."
          fields={[{ name: 'staff', label: 'Credit it to', type: 'select', options: opts, required: true }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} /> : null)} />
    </>
  );
}
