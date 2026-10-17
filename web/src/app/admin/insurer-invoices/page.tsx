import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Filters, PageHead, Table, t, d } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurer invoices', path: '/admin/insurer-invoices', noindex: true, description: 'Bill insurers and record their payments.' });
type R = Record<string, unknown>;

// Insurer invoices (03-admin.md section 7.4): drafted from a booking, sent, paid or written off.
export default async function InsurerInvoices({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/insurer-invoices'), searchParams]);
  const { rows } = await list('insurer_invoices', { eq: sp.status ? { status: sp.status } : {}, limit: 200 });
  const days = (iso: unknown) => typeof iso === 'string' ? Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000) : null;
  const R = ['/admin/insurer-invoices'];
  return (<>
    <PageHead title="Insurer invoices" kicker="Draft one from a booking billed to an insurer (booking page, Draft insurer invoice)" />
    <Filters base="/admin/insurer-invoices" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['draft', 'Draft'], ['sent', 'Sent'], ['part_paid', 'Part paid'], ['paid', 'Paid'], ['written_off', 'Written off']]} />
    <Table<R> testId="insurer-invoices" rows={rows} empty="No insurer invoices. They are made from a booking billed to an insurer, once it is returned." cols={[{ key: 'invoice_number', label: 'Invoice' }, { key: 'insurer_name', label: 'Insurer' }, { key: 'claim_number', label: 'Claim' }, { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> },
      { key: 'period', label: 'Period', render: (r) => `${d(r.period_start)} to ${d(r.period_end)}` }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'hst_cents', label: 'HST', num: true, render: (r) => $(r.hst_cents) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
      { key: 'paid_cents', label: 'Paid', num: true, render: (r) => $(r.paid_cents) }, { key: 'balance_cents', label: 'Balance', num: true, render: (r) => $(r.balance_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'sent_at', label: 'Sent', render: (r) => t(r.sent_at) }, { key: 'out', label: 'Days out', num: true, render: (r) => ['sent', 'part_paid'].includes(String(r.status)) ? days(r.sent_at) : null },
      { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions">
        <a className="btn btn--ghost btn--sm" href={`/files/insurer_invoice/${String(r.id)}`} data-testid="insurer-invoice-pdf">PDF</a>
        {['draft', 'sent', 'part_paid'].includes(String(r.status)) && <Act ops action="insurer_invoice_email" payload={{ id: r.id }} label={r.status === 'draft' ? 'Send by email' : 'Email again'} variant={r.status === 'draft' ? 'primary' : 'ghost'} testId="insurer-invoice-email"
          confirm={`Email invoice ${String(r.invoice_number)} to ${String(r.insurer_name ?? 'the insurer')}'s billing address with a link to the PDF (valid 7 days).${r.status === 'draft' ? ' The invoice is marked sent.' : ''}`} refresh={R} done="Queued to send." />}
        {r.status === 'draft' && <Act action="insurer_invoice_send" payload={{ id: r.id }} label="Mark sent (no email)" confirm="Record the invoice as sent without an email from here (sent another way)." refresh={R} />}
        {['sent', 'part_paid'].includes(String(r.status)) && <Act action="insurer_payment" payload={{ id: r.id }} label="Record payment" refresh={R} fields={[{ name: 'amount_cents', label: 'Amount received', type: 'money', required: true, value: r.balance_cents }, { name: 'method', label: 'Method', type: 'select', required: true, value: 'bank_transfer', options: [['bank_transfer', 'Bank transfer'], ['cheque', 'Cheque'], ['e_transfer', 'e-Transfer']] }, { name: 'reference', label: 'Reference' }, { name: 'paid_at', label: 'Received', type: 'datetime', value: new Date().toISOString() }]} />}
        {['sent', 'part_paid'].includes(String(r.status)) && <Act action="insurer_write_off" payload={{ id: r.id }} label="Write off" variant="danger" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} />}</span> }]} />
  </>);
}
