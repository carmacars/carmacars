import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { PageHead, bookingHref, label } from '@/features/admin/ui';
import { SalesBoard, type StaffSales } from '@/features/va/SalesBoard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sales', path: '/admin/staff', noindex: true, description: 'A staff member\'s commissions, quotes, offers, bookings and booked revenue.' });

// Admin > People > Staff > a staff member > Sales (migrations 0057 and 0058): the same board as the staff member's My
// sales, with every booking linked; the credit of each deal and whether they sourced it can be changed (with a reason,
// kept in the booking's history and the audit log); a commission can be reversed; a flat rate can be set for the person.
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
        {s.staff.function && s.staff.function !== 'field' && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/staff/${id}/scorecard`}>Scorecard</Link>}
        <Act action="commission_rate_set" payload={{ staff: id }} label="Commission rate" testId="commission-rate-set" refresh={[base]} done="Saved."
          fields={[{ name: 'bps', label: 'Flat rate for this person (empty: the Program settings)', type: 'percent', value: s.staff.commission_bps ?? null }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} />
        <Act action="staff_household_set" payload={{ staff: id }} label="Home address" testId="staff-household-set" refresh={[base]} done="Saved."
          fields={[{ name: 'home_address', label: 'Home address (used only to spot a household rental, which earns no commission)', type: 'text' }, { name: 'home_postal_code', label: 'Postal code', type: 'text' }]} />
      </PageHead>
      <SalesBoard s={s} base={base} sp={sp} own={false} bookingHref={(x) => bookingHref(x.booking_number)}
        dealAction={(x) => (x.credited ? <Act action="sales_reassign" payload={{ booking: x.booking_number }} label="Reassign" testId={`reassign-${x.booking_number}`} refresh={[base]} done="Reassigned."
          fields={[{ name: 'staff', label: 'Credit it to', type: 'select', options: opts, required: true },
            { name: 'sourced', label: 'Did they source the client?', type: 'select', options: [['true', 'Yes: they earn the commission'], ['false', 'No: entered for CarmaCars']], required: true, value: x.sourced ? 'true' : 'false' },
            { name: 'reason', label: 'Reason', type: 'text', required: true }]} /> : null)}
        commissionAction={(r) => (r.kind === 'commission' && ['accruing', 'pending_approval', 'approved', 'paid'].includes(r.status) ? <Act action="commission_reverse" payload={{ id: r.id }} label="Reverse" testId={`reverse-${r.booking_number}`} refresh={[base]} done="Reversed."
          fields={[{ name: 'reason', label: 'Reason (for example a household rental)', type: 'text', required: true }]} /> : null)} />
    </>
  );
}
