import { More } from '@/features/portal/Chrome';
import { InvoiceRows } from '@/features/owner/Blocks';
import type { OwnerCtx } from '@/features/owner/ctx';

// Money > Invoices: your program fees, one invoice per vehicle; pay one that is due from its page.
export function InvoicesTab({ home }: OwnerCtx) {
  return (
    <>
      <p className="ph__purpose">Your program fees, one invoice per vehicle. Pay one that is due from its page.</p>
      <More summary="How billing works">
        <p className="small muted">The upfront invoice is the first and last month&apos;s Insurance Fee; the Tracker Install Fee has its own invoice. Fees are billed on the {home.auto_debit.terms.debit_day_text} of each month, rented or not, by pre-authorized debit. {home.auto_debit.terms.late_fee_rule}</p>
      </More>
      <InvoiceRows items={home.invoices} empty="No invoices yet. Your upfront invoice appears here once your terms are set." />
    </>
  );
}
