import { pageMeta } from '@/features/seo/meta';
import { More, PageHeader } from '@/features/portal/Chrome';
import { InvoiceRows } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Invoices', path: '/owner/invoices', noindex: true, description: 'Your upfront and monthly fee invoices.' });

export default async function OwnerInvoices() {
  const { home } = await requireOwner('/owner/invoices');
  return (
    <>
      <PageHeader title="Invoices" purpose="Your program fees, one invoice per vehicle. Pay one that is due from its page." />
      <More summary="How billing works">
        <p className="small muted">The upfront invoice is the first and last month&apos;s Insurance Fee; the Tracker Install Fee has its own invoice. Fees are billed on the {home.auto_debit.terms.debit_day_text} of each month, rented or not, by pre-authorized debit. {home.auto_debit.terms.late_fee_rule}</p>
      </More>
      <InvoiceRows items={home.invoices} empty="No invoices yet. Your upfront invoice appears here once your terms are set." />
    </>
  );
}
