import type { AdminPage } from '@/server/admin/api';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { door } from '@/server/door';
import { PageHead, Search, Tiles } from '@/features/admin/ui';
import { TrackerActions } from '@/features/admin/AdminForms';
import { Act } from '@/features/admin/Act';
import { InvoiceList, type InvoiceListData } from '@/features/owner-billing/InvoiceList';


const FILTERS: Array<[string, string]> = [['', 'All'], ['open', 'Open'], ['partly_paid', 'Partly paid'], ['failed', 'Failed'], ['in_arrears', 'In arrears']];

// Money > Owner money > Invoices (migration 0067; r27: a tab of Owner money, /admin/invoices redirects): every owner invoice, drafts and voids included, each with its own
// page; New invoice for any amount; the monthly run and the tracker invoices as before.
export async function Invoices({ ctx: { user }, sp }: { ctx: AdminPage; sp: Record<string, string | undefined> }) {
  const status = FILTERS.some(([k]) => k === sp.status) ? sp.status ?? '' : '';
  const data = await door<InvoiceListData>(user.id, 'ops_read', 'owner_invoices_admin', { status, q: sp.q ?? '' });
  return (
    <>
      <PageHead title="Owner invoices" purpose="What owners owe: every invoice, drafts and voids included. Open one to record a payment, void it or credit it." />
      <Tiles items={[
        { k: 'Open', v: String(data.counts.open), sub: 'waiting for payment', href: '/admin/owner-money?tab=invoices&status=open', warn: data.counts.open > 0 },
        { k: 'Drafts', v: String(data.counts.draft), sub: 'not issued yet', href: '/admin/owner-money?tab=invoices&status=draft' },
        { k: 'Paid', v: String(data.counts.paid), href: '/admin/owner-money?tab=invoices&status=paid' },
        { k: 'Void', v: String(data.counts.void), href: '/admin/owner-money?tab=invoices&status=void' }]} />
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)', alignItems: 'center' }}>
        <ListFilters id="admin-owner-money-invoices-status" base="/admin/owner-money?tab=invoices" sp={sp} chips={{ name: 'status', label: 'Status', value: status, options: FILTERS }} />
        <Search action="/admin/owner-money?tab=invoices" value={sp.q} placeholder="Invoice number or owner" />
      </div>
      <InvoiceList data={data} newHref="/admin/invoices/new" testId="admin-invoices" />
      <details className="pt-card"><summary className="link">The monthly run and tracker invoices</summary>
        <section className="stack" aria-label="Monthly run"><p className="small">The monthly run issues the invoices for the debit day in Program settings (normally the scheduled job). Run it by hand for a missed month; an invoice already issued is never issued twice.</p>
          <Act action="owner_invoices_run" label="Run the monthly invoices" fields={[{ name: 'month', label: 'Month (first day)', type: 'date', required: true, value: new Date().toISOString().slice(0, 8) + '01' }]} refresh={['/admin/owner-money']} /></section>
        <section className="stack" aria-label="Trackers"><p className="small">When trackers arrive: one Tracker Install invoice for each vehicle waiting for its tracker.</p><TrackerActions ownerId={null} vehicleId={null} label="Issue all tracker invoices" /></section>
      </details>
    </>
  );
}
