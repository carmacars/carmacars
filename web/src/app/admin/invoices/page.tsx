import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { day, monthOf } from '@/features/owner/Blocks';
import { invoiceStatus } from '@/features/owner/types';
import { adminInvoices, requireAdmin } from '@/server/admin/data';
import { TrackerActions } from '@/features/admin/AdminForms';
import { Act } from '@/features/admin/Act';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner invoices', path: '/admin/invoices', noindex: true, description: 'Owner invoices.' });

const FILTERS = [['', 'All'], ['open', 'Open'], ['paid', 'Paid'], ['failed', 'Failed'], ['in_arrears', 'In arrears']] as const;

export default async function AdminInvoices({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireAdmin('/admin/invoices'), searchParams]);
  const status = FILTERS.some(([k]) => k === sp.status) ? sp.status ?? '' : '';
  const rows = await adminInvoices(user, status);
  return (
    <>
      <h1 className="d2">Owner invoices</h1>
      <section className="pt-card" aria-label="Monthly run"><p className="small">The monthly run issues the invoices for the 15th (normally the scheduled job). Run it by hand for a missed month; an invoice already issued is never issued twice.</p>
        <Act action="owner_invoices_run" label="Run the monthly invoices" fields={[{ name: 'month', label: 'Month (first day)', type: 'date', required: true, value: new Date().toISOString().slice(0, 8) + '01' }]} refresh={['/admin/invoices']} /></section>
      <section className="pt-card" aria-label="Trackers"><p className="small">When trackers arrive: one Tracker Install invoice for each vehicle waiting for its tracker.</p><TrackerActions ownerId={null} vehicleId={null} label="Issue all tracker invoices" /></section>
      <nav className="row" aria-label="Filter">{FILTERS.map(([k, l]) => <Link prefetch={false} key={k} className={`btn btn--sm ${status === k ? 'btn--primary' : 'btn--ghost'}`} href={k ? `/admin/invoices?status=${k}` : '/admin/invoices'} aria-current={status === k ? 'page' : undefined}>{l}</Link>)}</nav>
      {rows.length ? <ul className="ow-rows" data-testid="admin-invoices">{rows.map((i) => { const s = invoiceStatus(i); return (
        <li key={i.id}><Link prefetch={false} className="ow-row-link" href={`/admin/owners/${i.owner_id}#inv-${i.invoice_number}`}>{i.invoice_number} · {i.owner_name}</Link><span className="ow-amount">{money(i.total_cents, { cents: true })}</span>
          <span className="ow-meta"><span>{i.vehicle_name}</span><span>{i.kind === 'upfront' ? 'First and last month' : i.kind === 'tracker_install' ? 'Tracker install' : monthOf(i.period_month)}</span><span>Issued {day(i.billing_date)}</span><span className={`badge ${s.badge}`}>{s.label}</span>{i.balance_cents > 0 && i.status !== 'paid' && <span>Balance {money(i.balance_cents, { cents: true })}</span>}</span></li>); })}</ul>
        : <p className="pt-empty muted">No invoices.</p>}
    </>
  );
}
