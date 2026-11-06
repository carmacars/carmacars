import Link from '@/components/Link';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { $, Card, Table, d } from '@/features/admin/ui';
import { Builder, type InvoiceIn, type Partner } from './Builder';
import { METHODS, STATE_WORDS } from './model';

// Partner invoices (migration 0547): every invoice with its state, the totals invoiced, received and outstanding per
// partner and per claim, the builder, one invoice with its payments (record a cheque, e-Transfer or cash), send again,
// void, the PDF; the CSV for the bookkeeper. Admin (People > Referral partners > Invoices) and Finance (Money).
type L = { invoices: Array<Record<string, unknown>>; by_partner: Array<Record<string, unknown>>; by_claim: Array<Record<string, unknown>>;
  totals: { invoiced_cents: number; received_cents: number; outstanding_cents: number; overdue: number }; partners: Partner[] };
type One = InvoiceIn & { id: string; invoice_number: string | null; status: string; state: string; total_cents: number; paid_cents: number; balance_cents: number; sent_to: string | null; sends: number;
  view_token: string; partner: { business_name: string; email: string | null }; payments: Array<{ id: string; method: string; amount_cents: number; received_on: string; reference: string | null; voided_at: string | null }> };

export async function PartnerInvoices({ userId, aal, base, sp, partner }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: string; sp: Record<string, string | undefined>; partner?: string }) {
  const l = await door<L>(userId, 'ops_read', 'partner_invoices', { partner: partner ?? sp.partner ?? '', claim: sp.claim ?? '' }, aal);
  const refresh = [base.split('?')[0]!];
  const one = sp.invoice ? await door<One>(userId, 'ops_read', 'partner_invoices', { id: sp.invoice }, aal).catch(() => null) : null;
  const link = (q: string) => `${base}${base.includes('?') ? '&' : '?'}${q}`;
  return (
    <div className="stack" data-testid="partner-invoices">
      <p className="small">Invoiced {$(l.totals.invoiced_cents)} · received {$(l.totals.received_cents)} · <b>outstanding {$(l.totals.outstanding_cents)}</b>{l.totals.overdue ? ` · ${l.totals.overdue} overdue` : ''} · <a className="link" href="/api/staff/partner-invoice?csv=1">CSV for the bookkeeper</a></p>
      {one ? <Card title={`Invoice ${one.invoice_number ?? '(draft)'} · ${one.partner.business_name}`} testId="pi-one">
        <p>{STATE_WORDS[one.state] ?? one.state} · total {$(one.total_cents)} · received {$(one.paid_cents)} · balance <b>{$(one.balance_cents)}</b>{one.sent_to ? ` · sent to ${one.sent_to} (${one.sends}x)` : ''}</p>
        <p className="row"><a className="btn btn--ghost btn--sm" href={`/api/staff/partner-invoice?id=${one.id}`} target="_blank" rel="noreferrer">PDF</a>
          {one.status !== 'void' && <Act ops action="partner_invoice_send" payload={{ id: one.id }} label={one.status === 'draft' ? 'Send to the partner' : 'Send again'} refresh={refresh} done="Sent."
            fields={[{ name: 'to', label: 'To (empty: the partner\'s email)', type: 'email', value: one.partner.email ?? '' }]} />}
          {one.status === 'sent' && <Act ops action="partner_invoice_pay" payload={{ id: one.id }} label="Record money received" variant="primary" refresh={refresh} done="Recorded."
            fields={[{ name: 'method', label: 'How', type: 'select', required: true, options: METHODS.map(([k, v]) => [k, v] as [string, string]) }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true, value: one.balance_cents },
              { name: 'received_on', label: 'Received on', type: 'date' }, { name: 'reference', label: 'Cheque number or e-Transfer reference' }, { name: 'note', label: 'Note' }]} />}
          {one.status !== 'void' && <Act ops action="partner_invoice_void" payload={{ id: one.id }} label="Void" variant="danger" refresh={refresh} done="Void." fields={[{ name: 'reason', label: 'Why', required: true }]} />}</p>
        {one.payments.length > 0 && <Table rows={one.payments as unknown as Array<Record<string, unknown>>} cols={[{ key: 'received_on', label: 'Received', render: (r) => d(r.received_on) }, { key: 'method', label: 'How', render: (r) => METHODS.find(([k]) => k === r.method)?.[1] ?? String(r.method) },
          { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'reference', label: 'Reference' }, { key: 'voided_at', label: '', render: (r) => (r.voided_at ? 'Voided' : <Act ops action="partner_invoice_pay" payload={{ id: one.id, void_payment: r.id }} label="Void" confirm="Void this payment?" refresh={refresh} />) }]} />}
        {one.status === 'draft' && <Builder partners={l.partners} inv={one} refresh={refresh} base={base} />}
        <p><Link prefetch={false} className="link" href={base}>All invoices</Link></p>
      </Card> : <Card title="New invoice to a partner" testId="pi-new"><Builder partners={l.partners} refresh={refresh} base={base} /></Card>}
      <Card title="Invoices"><Table rows={l.invoices} empty="No invoices to partners yet." cols={[
        { key: 'invoice_number', label: 'Invoice', render: (r) => <Link prefetch={false} className="link" href={link(`invoice=${String(r.id)}`)}>{String(r.invoice_number ?? 'Draft')}</Link> },
        { key: 'partner', label: 'Partner' }, { key: 'claim_number', label: 'Claim', render: (r) => (r.claim_number ? <Link prefetch={false} className="link" href={link(`claim=${encodeURIComponent(String(r.claim_number))}`)}>{String(r.claim_number)}</Link> : '') },
        { key: 'state', label: 'Status', render: (r) => STATE_WORDS[String(r.state)] ?? String(r.state) }, { key: 'due_on', label: 'Due', render: (r) => d(r.due_on) },
        { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }, { key: 'paid_cents', label: 'Received', num: true, render: (r) => $(r.paid_cents) }, { key: 'balance_cents', label: 'Outstanding', num: true, render: (r) => $(r.balance_cents) }]} /></Card>
      <Card title="By partner"><Table rows={l.by_partner} empty="Nothing sent yet." cols={[{ key: 'partner', label: 'Partner' }, { key: 'invoiced_cents', label: 'Invoiced', num: true, render: (r) => $(r.invoiced_cents) },
        { key: 'received_cents', label: 'Received', num: true, render: (r) => $(r.received_cents) }, { key: 'outstanding_cents', label: 'Outstanding', num: true, render: (r) => $(r.outstanding_cents) }]} /></Card>
      <Card title="By claim"><Table rows={l.by_claim} empty="No invoice names a claim yet." cols={[{ key: 'claim_number', label: 'Claim' }, { key: 'invoices', label: 'Invoices', num: true }, { key: 'invoiced_cents', label: 'Invoiced', num: true, render: (r) => $(r.invoiced_cents) },
        { key: 'received_cents', label: 'Received', num: true, render: (r) => $(r.received_cents) }, { key: 'outstanding_cents', label: 'Outstanding', num: true, render: (r) => $(r.outstanding_cents) }]} /></Card>
    </div>
  );
}
