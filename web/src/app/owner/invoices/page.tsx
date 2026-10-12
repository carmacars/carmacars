import { pageMeta } from '@/features/seo/meta';
import { InvoiceRows } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Invoices', path: '/owner/invoices', noindex: true, description: 'Your upfront and monthly fee invoices.' });

export default async function OwnerInvoices() {
  const { home } = await requireOwner('/owner/invoices');
  return (
    <>
      <header className="stack"><h1 className="d2">Invoices</h1>
        <p className="muted">One invoice per vehicle. The upfront invoice is the first and last month&apos;s Insurance Fee; the Tracker Install Fee has its own invoice. Fees are billed on the 15th of each month, rented or not, by pre-authorized debit.</p></header>
      <InvoiceRows items={home.invoices} empty="No invoices yet. Your upfront invoice appears here once your terms are set." />
    </>
  );
}
