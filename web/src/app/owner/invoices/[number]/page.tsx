import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { Back } from '@/features/portal/Blocks';
import { day, monthOf } from '@/features/owner/Blocks';
import { OwnerPayForm } from '@/features/owner/OwnerPayForm';
import { invoiceStatus, invoiceTitle, PAY_METHOD_LABEL } from '@/features/owner/types';
import { ownerInvoice, requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Invoice', path: '/owner/invoices', noindex: true, description: 'An owner invoice and how to pay it.' });

const LINE_HST = (cents: number) => (cents ? money(cents, { cents: true }) : '');

// One invoice (11-statements-and-reports.md section 5) and the pay form: card or Canadian
// pre-authorized debit. The same page serves the upfront invoice and the monthly fee invoices.
export default async function OwnerInvoicePage({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, home }, p, sp] = await Promise.all([requireOwner('/owner/invoices'), params, searchParams]);
  const i = await ownerInvoice(user, decodeURIComponent(p.number));
  const s = invoiceStatus(i);
  const paid = i.payments.find((x) => x.status === 'succeeded');
  const pending = i.payments.find((x) => x.status === 'pending');
  const failed = i.payments.find((x) => x.status === 'failed');
  return (
    <>
      <Back href="/owner/invoices">Invoices</Back>
      <header className="stack">
        <p className="pt-kicker">Invoice {i.invoice_number}</p>
        <h1 className="d2">{invoiceTitle(i, monthOf)}</h1>
        <p className="muted">{i.vehicle_name}{i.plate ? `, plate ${i.plate}` : ''}. Issued {day(i.issued_at ?? i.billing_date)}.</p>
        <p><span className={`badge ${s.badge}`} data-testid="invoice-status">{s.label}</span></p>
      </header>
      <div className="pt-split">
        <div className="stack-lg">
          {i.status === 'paid' ? (
            <section className="ow-status ow-status--paid" data-testid="invoice-paid" aria-labelledby="ow-paid">
              <h2 className="d3" id="ow-paid">{sp.paid ? 'Thank you. Payment received.' : 'Paid'}</h2>
              <p>{money(i.total_cents, { cents: true })} paid{i.paid_at ? ` on ${day(i.paid_at)}` : ''}{paid ? ` by ${PAY_METHOD_LABEL[paid.method] ?? paid.method}${paid.card_last4 ? ` ending ${paid.card_last4}` : ''}${paid.reference ? `, reference ${paid.reference}` : ''}` : ''}. A receipt is on its way to {i.owner_email ?? 'your email'}.</p>
              {i.kind === 'upfront' && <p className="small muted">Your first and last month&apos;s Insurance Fee are now held for this vehicle. The first pays the month it is enrolled; the last pays the month it leaves.</p>}
              <p><Link prefetch={false} className="btn btn--ghost" href="/owner">Back to the owner portal</Link></p>
            </section>
          ) : pending ? (
            <section className="ow-status ow-status--pending" data-testid="invoice-pending" aria-labelledby="ow-pending">
              <h2 className="d3" id="ow-pending">Your debit is processing</h2>
              <p>{money(pending.amount_cents, { cents: true })} from the account ending {pending.card_last4 ?? '----'}. A pre-authorized debit takes 3 to 5 business days to clear. We email you when it does; nothing else to do.</p>
            </section>
          ) : i.payable ? (
            <section className="pt-card" aria-labelledby="ow-pay">
              <h2 className="d4" id="ow-pay">Pay {money(i.balance_cents, { cents: true })}</h2>
              {failed && <p className="alert alert--error" role="alert"><span className="alert__title">The last payment did not go through</span><span>{failed.decline ?? 'Please try again or use another method.'}</span></p>}
              <OwnerPayForm number={i.invoice_number} amountCents={i.balance_cents} ownerType={home.owner.owner_type} hasDebit={i.saved_methods.some((m) => m.kind === 'pre_authorized_debit')} />
            </section>
          ) : (
            <section className="pt-card"><h2 className="d4">Nothing to pay online</h2><p>This invoice is {s.label.toLowerCase()}. Questions: call or message us.</p></section>
          )}
          <section className="pt-card" aria-labelledby="ow-other"><h2 className="d4" id="ow-other">Paying by e-Transfer instead</h2>
            <p className="small">Send {money(i.balance_cents || i.total_cents, { cents: true })} by Interac e-Transfer to billing@carmacars.ca with <b>{i.invoice_number}</b> in the message. We mark the invoice paid when it arrives, usually the same business day.</p>
          </section>
        </div>
        <aside className="pt-split__aside pt-first">
          <section className="pt-card" aria-labelledby="ow-lines"><h2 className="d4" id="ow-lines">What this invoice covers</h2>
            <dl className="pt-dl pt-dl--money" data-testid="invoice-lines">
              {i.lines.filter((l) => l.kind !== 'late_fee').map((l, k) => <div key={k}><dt>{l.description ?? l.kind.replace(/_/g, ' ')}</dt><dd>{money(l.amount_cents, { cents: true })}</dd></div>)}
              <div><dt>HST{i.company_hst_number ? ` (${i.company_hst_number})` : ''}</dt><dd>{LINE_HST(i.hst_cents) || money(0, { cents: true })}</dd></div>
              {i.late_fee_cents > 0 && <div><dt>Late Fee (no HST)</dt><dd>{money(i.late_fee_cents, { cents: true })}</dd></div>}
              <div><dt><b>Total</b></dt><dd className="pt-total" data-testid="invoice-total">{money(i.total_cents, { cents: true })}</dd></div>
              {i.paid_cents > 0 && i.status !== 'paid' && <div><dt>Paid so far</dt><dd>{money(-i.paid_cents, { cents: true })}</dd></div>}
              {i.status !== 'paid' && <div><dt><b>Balance</b></dt><dd className="pt-total">{money(i.balance_cents, { cents: true })}</dd></div>}
            </dl>
            {i.kind === 'monthly' && i.days_billed && i.days_in_month && i.days_billed < i.days_in_month && <p className="small muted">Pro-rated: {i.days_billed} of {i.days_in_month} days.</p>}
            <p className="small muted">{i.kind === 'upfront' && !home.trackers_available ? 'The Tracker Install Fee is billed on its own invoice when trackers become available. ' : ''}Fees are due every month, rented or not. Registry, inspection and appraisal costs are not billed by CarmaCars: you pay them directly.</p>
          </section>
          {i.payments.length > 0 && (
            <section className="pt-card" aria-labelledby="ow-payments"><h2 className="d4" id="ow-payments">Payments</h2>
              <ul className="ow-rows">{i.payments.map((x) => <li key={x.id}><span>{PAY_METHOD_LABEL[x.method] ?? x.method}{x.card_last4 ? ` ending ${x.card_last4}` : ''}{x.reference ? ` · ${x.reference}` : ''}</span><span className="ow-amount">{money(x.amount_cents, { cents: true })}</span><span className="ow-meta"><span>{x.status === 'succeeded' ? 'Received' : x.status === 'pending' ? 'Processing' : 'Did not go through'}</span><span>{day(x.processed_at ?? x.created_at)}</span></span></li>)}</ul>
            </section>
          )}
        </aside>
      </div>
    </>
  );
}
