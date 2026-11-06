import '@/styles/portal-revamp.css';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { loadPortal, partnerLink } from '@/server/referral/portal';
import { dollars, kindLabel } from '@/features/referral/model';
import { CopyLink } from '@/features/portal/CopyLink';
import { NowPanel } from '@/features/portal-nav/NowPanel';
import { rpc } from '@/lib/db/repo';

// A referral partner's own page (migration 0164): the link only they hold. Their referrals by the customer's first name and the
// month, what is waiting and what was paid. No sign-in, no customer details beyond that, never indexed. The r27 portals
// revamp: the totals in the dark band first, the link and code with Copy, the referrals as rows (cards on a phone).
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your CarmaCars referrals', path: '/partners/portal', noindex: true, description: 'Your referrals and earnings.' });

const chip = (status: string) => (/paid/i.test(status) ? 'rp-chip--paid' : /cancel|refund|charge|void|none/i.test(status) ? 'rp-chip--none' : 'rp-chip--waiting');

export default async function PartnerPortal({ params }: { params: Promise<{ id: string; key: string }> }) {
  const { id, key } = await params;
  const d = await loadPortal(id, key);
  if (!d) notFound();
  const link = partnerLink(d.partner.referral_code);
  // 0547: invoices CarmaCars sent this partner, read only, with how to pay
  const invoices = ((await rpc('server_partner_invoices_of' as never, { p_partner: id } as never, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as Array<{ invoice_number: string; state: string; issued_on: string; due_on: string | null; claim_number: string | null; total_cents: number; balance_cents: number; view_token: string }> | null) ?? [];
  const t = d.totals;
  return (
    <div className="wrap rp" data-testid="partner-portal">
      <header className="rp__head">
        <p className="rp__kicker">{kindLabel(d.partner.kind)} referral program</p>
        <h1 className="d2">{d.partner.business_name}</h1>
        <p className="muted">You earn {d.partner.rate_text} on each rental that came through your link or code, once it is finished and paid in full.</p>
        {d.partner.status !== 'active' && <p className="alert alert--warn" role="status"><span>Your partnership is {d.partner.status}: new referrals are not counted. Call or message us to restart it.</span></p>}
      </header>
      <NowPanel testId="portal-totals" titleId="pp-totals" kicker="Your earnings" headline={t.paid_cents > 0 ? `${dollars(t.paid_cents)} paid to you so far` : t.referrals > 0 ? `${t.referrals} referred ${t.referrals === 1 ? 'rental' : 'rentals'} so far` : 'Your first referral shows here'}
        detail={t.pending_cents > 0 ? `${dollars(t.pending_cents)} is approved or waiting for approval, paid with the next payment.` : 'A referral earns once the rental is finished and paid in full.'}
        facts={[
          { key: 'n', label: 'Referred rentals', value: String(t.referrals) },
          { key: 'acc', label: 'Rentals not finished yet', value: dollars(t.accruing_cents) },
          { key: 'pend', label: 'Approved or waiting', value: dollars(t.pending_cents) },
          { key: 'paid', label: 'Paid to you', value: dollars(t.paid_cents) }
        ]} />
      <section className="rp__link" aria-labelledby="pp-link">
        <h2 className="d4" id="pp-link">Your link and code</h2>
        <div className="rp__code">
          <span>Code <b data-testid="portal-code">{d.partner.referral_code}</b></span>
          <CopyLink url={d.partner.referral_code} label="Copy the code" />
        </div>
        <div className="rp__code">
          <span className="small" style={{ overflowWrap: 'anywhere' }}>Link <b className="small" data-testid="portal-link">{link.replace(/^https?:\/\//, '')}</b></span>
          <CopyLink url={link} label="Copy the link" />
        </div>
        <p className="small muted">Customers can scan your QR code, open your link, or give us your code. Ask us for a new flyer any time.</p>
      </section>
      {invoices.length > 0 && <section className="stack" aria-labelledby="pp-inv" data-testid="portal-invoices">
        <h2 className="d3" id="pp-inv">Invoices from CarmaCars</h2>
        <ul className="rp__rows">{invoices.map((v) => (
          <li key={v.invoice_number} className="rp__row"><b><a className="link" href={`/api/partner-invoice/${v.view_token}`} target="_blank" rel="noreferrer">{v.invoice_number}</a></b>
            <span className="rp__amt">{dollars(v.balance_cents)} due</span>
            <span className="rp__meta">{v.claim_number ? `Claim ${v.claim_number} · ` : ''}total {dollars(v.total_cents)}{v.due_on ? ` · due ${v.due_on}` : ''} · <span className={`rp-chip ${chip(v.state)}`}>{v.state.replace('_', ' ')}</span></span></li>))}</ul>
        <p className="small muted">Pay by cheque or e-Transfer as each invoice says, quoting its number.</p>
      </section>}
      <section className="stack" aria-labelledby="pp-rows">
        <h2 className="d3" id="pp-rows">Your referrals</h2>
        {d.rows.length === 0 ? <p className="pt-empty muted" style={{ borderRadius: 14, border: '1px dashed var(--grey-300)', padding: 'var(--s-4)' }}>No referrals yet. Your first one shows here as soon as a customer sends a request with your link or code.</p> : (
          <ul className="rp__rows" data-testid="portal-rows">{d.rows.map((r, i) => (
            <li key={i} className="rp__row">
              <b>{r.first_name || 'Customer'}</b>
              <span className="rp__amt">{dollars(r.amount_cents)}</span>
              <span className="rp__meta">{r.month} · <span className={`rp-chip ${chip(r.status)}`}>{r.status}{r.paid_on ? ` ${r.paid_on}` : ''}</span></span>
            </li>))}
          </ul>
        )}
        <p className="small muted">A referral shows the customer&apos;s first name and the month of the rental, nothing more. A rental that is cancelled, refunded or charged back earns nothing; a fee already paid for one comes off the next payment.</p>
      </section>
    </div>
  );
}
