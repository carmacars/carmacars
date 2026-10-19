import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { adminOwners } from '@/server/admin/data';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { InvoiceEditor } from '@/features/owner-billing/InvoiceEditor';
import type { InvoiceListData } from '@/features/owner-billing/InvoiceList';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'New owner invoice', path: '/admin/invoices/new', noindex: true, description: 'A new owner invoice.' });

// A new owner invoice of any amount (migration 0067), for an owner's car: from the owner page, the application or
// Money > Owner invoices. Saved as a draft first; issued when the Admin says so.
export default async function NewInvoice({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/invoices/new'), searchParams]);
  const owner = /^[0-9a-f-]{36}$/.test(sp.owner ?? '') ? sp.owner! : null;
  const app = /^[0-9a-f-]{36}$/.test(sp.application ?? '') ? sp.application! : null;
  const facts = await door<{ hst_bps: number }>(user.id, 'ops_read', 'owner_add_car_facts', {});
  if (!owner && !app) {
    const owners = await adminOwners(user);
    return (
      <>
        <PageHead kicker={<Link prefetch={false} className="link" href="/admin/invoices">Owner invoices</Link>} title="New invoice" />
        <p>Choose the owner.</p>
        <ul className="ad-list" data-testid="invoice-new-owners">{owners.map((o) => <li key={o.owner_id}><Link prefetch={false} className="link" href={`/admin/invoices/new?owner=${o.owner_id}`}>{o.legal_name}</Link><span className="small">{o.vehicles} car{o.vehicles === 1 ? '' : 's'}</span></li>)}</ul>
      </>
    );
  }
  const data = await door<InvoiceListData>(user.id, 'ops_read', 'owner_invoices_admin', owner ? { owner_id: owner } : { application_id: app });
  const back = owner ? `/admin/owners/${owner}?tab=invoices` : `/admin/applications/${app}?tab=invoices`;
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href={back}>Back</Link>} title="New invoice" />
      <div style={{ maxWidth: '60rem' }}>
        {data.cars.length ? <InvoiceEditor cars={data.cars} applicationId={app ?? undefined} hstBps={facts.hst_bps} paths={[back.split('?')[0]!]} />
          : <p className="alert alert--warn"><span>This owner has no car in the program to invoice.</span></p>}
      </div>
    </>
  );
}
