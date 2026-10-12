import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { day, InvoiceRows, VehicleCard } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner portal', path: '/owner', noindex: true, description: 'Your vehicles, agreements, invoices, statements and payouts with CarmaCars.' });

// Home (04-owner.md section 2): the one next thing to do, then the vehicles with their checklist, money and notices.
export default async function OwnerHomePage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ home }, sp] = await Promise.all([requireOwner('/owner'), searchParams]);
  const due = home.invoices.filter((i) => i.payable);
  const pending = home.invoices.filter((i) => i.pending && i.status !== 'paid');
  const next = home.signing.needed
    ? { title: 'Sign your agreements', note: `Your Vehicle Enrollment Agreement and Vehicle Schedule are ready${home.signing.title_holding && home.signing.title_holding !== 'signed' ? ', with the Title-Holding and Lease Agreement' : ''}. Read them and sign once, on this screen.`, href: '/owner/sign', cta: 'Read and sign' }
    : due.length
      ? { title: due.length === 1 ? `Pay invoice ${due[0]!.invoice_number}` : `Pay ${due.length} invoices`, note: `${money(due.reduce((s, i) => s + i.balance_cents, 0), { cents: true })} due: ${due.map((i) => i.vehicle_name).join(', ')}. Pay by card or pre-authorized debit.`, href: due.length === 1 ? `/owner/invoices/${due[0]!.invoice_number}` : '/owner/invoices', cta: due.length === 1 ? 'Pay now' : 'See invoices' }
      : null;
  const fees = home.vehicles.reduce((s, v) => s + (v.status !== 'exited' && v.insurance_fee_cents ? v.insurance_fee_cents + (v.tracker_fee_cents ?? 0) : 0), 0);
  return (
    <>
      {sp.signed && <p className="alert alert--ok" role="status"><span className="alert__title">Signed</span><span>Thank you. Your signed agreements are in Documents.</span></p>}
      {sp.applied && <p className="alert alert--ok" role="status"><span className="alert__title">Application received</span><span>We reply within 1 business day with the terms for each vehicle.</span></p>}
      <header className="stack"><p className="pt-kicker">Owner portal</p><h1 className="d2">Hello, {home.owner.first_name}</h1></header>
      {!home.vehicles.length ? (
        <div className="pt-empty"><p className="d4">Add your first vehicle</p><p className="muted">Apply once and add every vehicle you want to enrol.</p><Link className="btn btn--primary" href="/list-your-car/apply">Add a vehicle</Link></div>
      ) : (
        <div className="pt-home">
          {next ? (
            <section className="pt-card pt-card--next" aria-labelledby="ow-next" data-testid="owner-next-step">
              <p className="pt-kicker">Next step</p>
              <h2 className="d3" id="ow-next">{next.title}</h2>
              <p>{next.note}</p>
              <p><Link className="btn btn--primary" href={next.href}>{next.cta}</Link></p>
            </section>
          ) : pending.length ? (
            <section className="pt-card pt-card--next" aria-labelledby="ow-next" data-testid="owner-next-step"><p className="pt-kicker">In progress</p><h2 className="d3" id="ow-next">Your payment is processing</h2><p>A pre-authorized debit takes 3 to 5 business days to clear. We email you when it does.</p></section>
          ) : null}
          <section className="stack" aria-labelledby="ow-cars">
            <div className="row" style={{ justifyContent: 'space-between' }}><h2 className="pt-section-title" id="ow-cars">Your vehicles</h2><Link className="btn btn--ghost btn--sm" href="/list-your-car/apply">Add a vehicle</Link></div>
            <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact />)}</ul>
          </section>
          <section className="stack" aria-labelledby="ow-money">
            <h2 className="pt-section-title" id="ow-money">Money</h2>
            <div className="ow-tiles">
              <div className="ow-tile"><span>Due now</span><b data-testid="owner-due">{money(due.reduce((s, i) => s + i.balance_cents, 0), { cents: true })}</b></div>
              <div className="ow-tile"><span>Fees each month, before HST</span><b>{money(fees)}</b></div>
              <div className="ow-tile"><span>Next billing date</span><b>{day(home.next_billing_date)}</b></div>
              <div className="ow-tile"><span>Next payout date</span><b>{day(home.next_payout_date)}</b></div>
            </div>
            <InvoiceRows items={home.invoices.slice(0, 5)} />
            {home.invoices.length > 5 && <p><Link href="/owner/invoices">All invoices</Link></p>}
            {!home.payout_accounts.length && <p className="pt-note">Add the bank account we pay you into: <Link href="/owner/banking">Banking</Link>.</p>}
          </section>
        </div>
      )}
    </>
  );
}
