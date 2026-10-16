import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { day, InvoiceRows, VehicleCard } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';
import { rpc } from '@/lib/db/repo';
import { TRACKER_LATER } from '@/features/owner/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner portal', path: '/owner', noindex: true, description: 'Your vehicles, agreements, invoices, statements and payouts with CarmaCars.' });

// Home (04-owner.md section 2): the one next thing to do, then the vehicles with their checklist, money and notices.
export default async function OwnerHomePage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, home }, sp] = await Promise.all([requireOwner('/owner'), searchParams]);
  // what is left to sign on screen (0049): one package on /owner/sign
  const checklist = (await rpc('server_my_signing_checklist', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { items: Array<{ status: string; how: string; label: string }>; done: number; total: number } | null;
  const onScreen = (checklist?.items ?? []).filter((i) => i.status === 'open' && (i.how === 'screen' || i.how === 'registry'));
  const due = home.invoices.filter((i) => i.payable);
  const pending = home.invoices.filter((i) => i.pending && i.status !== 'paid');
  const partner = home.kind === 'partner' ? home.partner ?? null : null;
  const next = partner && partner.agreement_status !== 'signed'
    ? { title: 'Sign your partner agreement', note: `Your partner agreement with CarmaCars is ready: your cars, our commission and how we pay you. It is filled in for you; check it and sign on this screen.`, href: '/owner/sign', cta: 'Check and sign' }
    : home.signing.needed || onScreen.length
    ? { title: `Sign your documents (${checklist ? `${checklist.done} of ${checklist.total} signed` : 'ready'})`, note: `${onScreen.map((i) => i.label).filter((v, n, a) => a.indexOf(v) === n).join(', ') || 'Your agreements'}: filled in from what you gave us. Check the key values and sign once for all of them, in about a minute.`, href: '/owner/sign', cta: 'Check and sign' }
    : due.length
      ? { title: due.length === 1 ? `Pay invoice ${due[0]!.invoice_number}` : `Pay ${due.length} invoices`, note: `${money(due.reduce((s, i) => s + i.balance_cents, 0), { cents: true })} due: ${due.map((i) => i.vehicle_name).join(', ')}. Pay by card or pre-authorized debit.`, href: due.length === 1 ? `/owner/invoices/${due[0]!.invoice_number}` : '/owner/invoices', cta: due.length === 1 ? 'Pay now' : 'See invoices' }
      : null;
  const fees = home.vehicles.reduce((s, v) => s + (v.status !== 'exited' && v.insurance_fee_cents ? v.insurance_fee_cents + (home.trackers_available ? v.tracker_fee_cents ?? 0 : 0) : 0), 0);
  return (
    <>
      {sp.signed && <p className="alert alert--ok" role="status"><span className="alert__title">Signed</span><span>Thank you. Your signed agreements are in Documents.</span></p>}
      {sp.applied && <p className="alert alert--ok" role="status"><span className="alert__title">Application received</span><span>We reply within 1 business day with the terms for each vehicle.</span></p>}
      <header className="stack"><p className="pt-kicker">{partner ? `Partner portal · ${partner.partner_number}` : 'Owner portal'}</p><h1 className="d2">Hello, {home.owner.first_name}</h1></header>
      {!home.vehicles.length ? (
        partner ? <div className="pt-empty" data-testid="partner-no-cars"><p className="d4">No cars yet</p><p className="muted">CarmaCars adds your cars once we agree which ones join. Questions? Reply to any of our emails.</p>{partner.agreement_status !== 'signed' && <Link prefetch={false} className="btn btn--primary" href="/owner/partner-agreement">Read and sign your partner agreement</Link>}</div>
        : <div className="pt-empty"><p className="d4">Add your first vehicle</p><p className="muted">Apply once and add every vehicle you want to enrol.</p><Link prefetch={false} className="btn btn--primary" href="/list-your-car/apply">Add a vehicle</Link></div>
      ) : (
        <div className="pt-home">
          {next ? (
            <section className="pt-card pt-card--next" aria-labelledby="ow-next" data-testid="owner-next-step">
              <p className="pt-kicker">Next step</p>
              <h2 className="d3" id="ow-next">{next.title}</h2>
              <p>{next.note}</p>
              <p><Link prefetch={false} className="btn btn--primary" href={next.href}>{next.cta}</Link></p>
            </section>
          ) : pending.length ? (
            <section className="pt-card pt-card--next" aria-labelledby="ow-next" data-testid="owner-next-step"><p className="pt-kicker">In progress</p><h2 className="d3" id="ow-next">Your payment is processing</h2><p>A pre-authorized debit takes 3 to 5 business days to clear. We email you when it does.</p></section>
          ) : null}
          <section className="stack" aria-labelledby="ow-cars">
            <div className="row" style={{ justifyContent: 'space-between' }}><h2 className="pt-section-title" id="ow-cars">Your vehicles</h2>{!partner && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/list-your-car/apply">Add a vehicle</Link>}</div>
            <ul className="ow-cars">{home.vehicles.map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} />)}</ul>
          </section>
          <section className="stack" aria-labelledby="ow-money">
            <h2 className="pt-section-title" id="ow-money">Money</h2>
            <div className="ow-tiles">
              {partner && <div className="ow-tile" data-testid="partner-commission"><span>CarmaCars commission</span><b>{(partner.commission_effective_bps / 100).toFixed(partner.commission_effective_bps % 100 ? 2 : 0)}%</b></div>}
              <div className="ow-tile"><span>Due now</span><b data-testid="owner-due">{money(due.reduce((s, i) => s + i.balance_cents, 0), { cents: true })}</b></div>
              <div className="ow-tile"><span>Fees each month, before HST</span><b>{money(fees)}</b></div>
              <div className="ow-tile" data-testid="owner-next-debit"><span>{home.auto_debit.next_debit_on ? 'Next debit' : 'Next billing date'}</span><b>{home.auto_debit.next_debit_on ? `${money(home.auto_debit.next_debit_cents, { cents: true })} on ${day(home.auto_debit.next_debit_on)}` : day(home.next_billing_date)}</b></div>
              <div className="ow-tile"><span>Next payout date</span><b>{day(home.next_payout_date)}</b></div>
            </div>
            <InvoiceRows items={home.invoices.slice(0, 5)} />
            {home.invoices.length > 5 && <p><Link prefetch={false} href="/owner/invoices">All invoices</Link></p>}
            {!home.trackers_available && home.tracker_pending.length > 0 && <p className="small muted">{TRACKER_LATER}</p>}
            {!home.payout_accounts.length && <p className="pt-note">Add the bank account we pay you into: <Link prefetch={false} href="/owner/banking">Banking</Link>.</p>}
            {home.auto_debit.enabled && !home.auto_debit.mandate && !home.auto_debit.pending_setup && home.invoices.some((i) => i.payable) && <p className="pt-note" data-testid="owner-debit-missing">Your fees are debited automatically once you set up a pre-authorized debit: <Link prefetch={false} href="/owner/banking">Banking</Link>.</p>}
          </section>
        </div>
      )}
    </>
  );
}
