import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { loadPortal, partnerLink } from '@/server/referral/portal';
import { dollars, kindLabel } from '@/features/referral/model';

// A referral partner's own page (migration 0164): the link only they hold. Their referrals by the customer's first name and the
// month, what is waiting and what was paid. No sign-in, no customer details beyond that, never indexed.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your CarmaCars referrals', path: '/partners/portal', noindex: true, description: 'Your referrals and earnings.' });

export default async function PartnerPortal({ params }: { params: Promise<{ id: string; key: string }> }) {
  const { id, key } = await params;
  const d = await loadPortal(id, key);
  if (!d) notFound();
  const link = partnerLink(d.partner.referral_code);
  return (
    <div className="wrap stack-lg" style={{ paddingBlock: '2rem' }} data-testid="partner-portal">
      <header className="stack">
        <p className="small muted">{kindLabel(d.partner.kind)} referral program</p>
        <h1 className="d2">{d.partner.business_name}</h1>
        <p className="muted">You earn {d.partner.rate_text} on each rental that came through your link or code, once it is finished and paid in full.{d.partner.status !== 'active' ? ` Your partnership is ${d.partner.status}: new referrals are not counted.` : ''}</p>
      </header>
      <section className="stack" aria-labelledby="pp-link">
        <h2 className="d3" id="pp-link">Your link and code</h2>
        <p>Link: <b data-testid="portal-link">{link.replace(/^https?:\/\//, '')}</b> &nbsp; Code: <b data-testid="portal-code">{d.partner.referral_code}</b></p>
        <p className="small muted">Customers can scan your QR code, open your link, or give us your code. Ask us for a new flyer any time.</p>
      </section>
      <section aria-labelledby="pp-totals">
        <h2 className="d3" id="pp-totals">Your earnings</h2>
        <ul className="stack" data-testid="portal-totals">
          <li>Referred rentals: <b>{d.totals.referrals}</b></li>
          <li>Rentals not finished yet: <b>{dollars(d.totals.accruing_cents)}</b></li>
          <li>Approved or waiting for approval: <b>{dollars(d.totals.pending_cents)}</b></li>
          <li>Paid to you: <b>{dollars(d.totals.paid_cents)}</b></li>
        </ul>
      </section>
      <section className="stack" aria-labelledby="pp-rows">
        <h2 className="d3" id="pp-rows">Your referrals</h2>
        {d.rows.length === 0 ? <p className="muted">No referrals yet. Your first one shows here as soon as a customer sends a request with your link or code.</p> : (
          <div className="table-scroll" tabIndex={0} role="region" aria-label="Your referrals"><table className="data" data-testid="portal-rows">
            <thead><tr><th scope="col">Customer</th><th scope="col">Month</th><th scope="col">Status</th><th scope="col" className="num">Amount</th></tr></thead>
            <tbody>{d.rows.map((r, i) => <tr key={i}><td>{r.first_name || 'Customer'}</td><td>{r.month}</td><td>{r.status}{r.paid_on ? ` (${r.paid_on})` : ''}</td><td className="num">{dollars(r.amount_cents)}</td></tr>)}</tbody>
          </table></div>
        )}
        <p className="small muted">A referral shows the customer&apos;s first name and the month of the rental, nothing more. A rental that is cancelled, refunded or charged back earns nothing; a fee already paid for one comes off the next payment.</p>
      </section>
    </div>
  );
}
