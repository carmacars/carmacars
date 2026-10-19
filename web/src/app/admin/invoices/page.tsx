import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Filters, PageHead, Search } from '@/features/admin/ui';
import { TrackerActions } from '@/features/admin/AdminForms';
import { Act } from '@/features/admin/Act';
import { InvoiceList, type InvoiceListData } from '@/features/owner-billing/InvoiceList';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner invoices', path: '/admin/invoices', noindex: true, description: 'Owner invoices.' });

const FILTERS: Array<[string, string]> = [['', 'All'], ['draft', 'Drafts'], ['open', 'Open'], ['partly_paid', 'Partly paid'], ['paid', 'Paid'], ['failed', 'Failed'], ['in_arrears', 'In arrears'], ['void', 'Void']];

// Admin > Money > Owner invoices (migration 0067): every owner invoice, drafts and voids included, each with its own
// page; New invoice for any amount; the monthly run and the tracker invoices as before.
export default async function AdminInvoices({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/invoices'), searchParams]);
  const status = FILTERS.some(([k]) => k === sp.status) ? sp.status ?? '' : '';
  const data = await door<InvoiceListData>(user.id, 'ops_read', 'owner_invoices_admin', { status, q: sp.q ?? '' });
  return (
    <>
      <PageHead title="Owner invoices" />
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)', alignItems: 'center' }}>
        <Filters base="/admin/invoices" name="status" value={status} options={FILTERS} sp={sp} />
        <Search action="/admin/invoices" value={sp.q} placeholder="Invoice number or owner" />
      </div>
      <InvoiceList data={data} newHref="/admin/invoices/new" testId="admin-invoices" />
      <details className="pt-card"><summary className="link">The monthly run and tracker invoices</summary>
        <section className="stack" aria-label="Monthly run"><p className="small">The monthly run issues the invoices for the debit day in Program settings (normally the scheduled job). Run it by hand for a missed month; an invoice already issued is never issued twice.</p>
          <Act action="owner_invoices_run" label="Run the monthly invoices" fields={[{ name: 'month', label: 'Month (first day)', type: 'date', required: true, value: new Date().toISOString().slice(0, 8) + '01' }]} refresh={['/admin/invoices']} /></section>
        <section className="stack" aria-label="Trackers"><p className="small">When trackers arrive: one Tracker Install invoice for each vehicle waiting for its tracker.</p><TrackerActions ownerId={null} vehicleId={null} label="Issue all tracker invoices" /></section>
      </details>
    </>
  );
}
