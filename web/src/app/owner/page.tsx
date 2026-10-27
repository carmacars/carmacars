import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money, plural } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { CarPhoto, day, InvoiceRows, VehicleCard } from '@/features/owner/Blocks';
import { ownerView, requireOwner } from '@/server/owner/data';
import { rpc } from '@/lib/db/repo';
import { TRACKER_LATER } from '@/features/owner/types';
import { ApplicationTask, type AppTask } from '@/features/owner/ApplicationTask';
import { amountText, carThisMonth, nextPayout, upcoming, viewOf } from '@/features/owner/insights';
import { OwnerMonths } from '@/features/owner/OwnerMonths';
import { PageHeader } from '@/features/portal/Chrome';
import { ActionTiles, Delta, PortalHero, Sparkline, StatCard, Timeline, TimelineItem, type ActionTileItem } from '@/components/portal-ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner portal', path: '/owner', noindex: true, description: 'Your vehicles, agreements, invoices, statements and payouts with CarmaCars.' });

// Home (04-owner.md section 2): the one next thing to do, then the cars live, the money and the months, what is coming up.
// The figures are the owner's own (features/owner/insights.ts): their cars, bookings, invoices and statements.
export default async function OwnerHomePage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, home }, sp] = await Promise.all([requireOwner('/owner'), searchParams]);
  // what is left to sign on screen (0049): one package on /owner/sign
  const checklist = (await rpc('server_my_signing_checklist', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { items: Array<{ status: string; how: string; label: string; preview?: boolean }>; done: number; total: number } | null;
  // what CarmaCars asked for on an application (0054), until the owner answers
  const appTask = (await rpc('server_owner_application_task', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as AppTask | null;
  const onScreen = (checklist?.items ?? []).filter((i) => i.status === 'open' && (i.how === 'screen' || i.how === 'registry'));
  // before approval (0180): the agreements can be read, filled in, and signed once the terms are approved
  const previewOnly = !home.signing.needed && onScreen.length > 0 && onScreen.every((i) => i.preview);
  // 0067: an updated Vehicle Schedule to sign comes first; cars set up by staff can be reviewed and corrected before signing
  const changes = ((await rpc('server_owner_schedule_changes', { p_by: user.id }, { role: 'service_role' }).catch(() => [])) ?? []) as unknown as Array<{ change_id: string; vehicle_name: string; effective_from: string }>;
  const view = await ownerView(user, home);
  const due = home.invoices.filter((i) => i.payable);
  const pending = home.invoices.filter((i) => i.pending && i.status !== 'paid');
  const partner = home.kind === 'partner' ? home.partner ?? null : null;
  const next = changes.length
    ? { title: `Sign the updated Vehicle Schedule for the ${changes[0]!.vehicle_name}`, note: `The terms we agreed apply from ${day(changes[0]!.effective_from)} once you sign. Your current terms stay until then.`, href: `/owner/sign/schedule/${changes[0]!.change_id}`, cta: 'Read and sign' }
    : partner && partner.agreement_status !== 'signed'
    ? { title: 'Sign your partner agreement', note: `Your partner agreement with CarmaCars is ready: your cars, our commission and how we pay you. It is filled in for you; check it and sign on this screen.`, href: '/owner/sign', cta: 'Check and sign' }
    : previewOnly
    ? { title: 'Your agreements are filled in: terms pending approval', note: 'Read them now, filled in from your application. You can sign once CarmaCars approves your terms; we email you when they are ready.', href: '/owner/sign', cta: 'Read your agreements' }
    : home.signing.needed || onScreen.length
    ? { title: `Sign your documents (${checklist ? `${checklist.done} of ${checklist.total} signed` : 'ready'})`, note: `${onScreen.map((i) => i.label).filter((v, n, a) => a.indexOf(v) === n).join(', ') || 'Your agreements'}: filled in from what you gave us. Check the key values and sign once for all of them, in about a minute.`, href: '/owner/sign', cta: 'Check and sign' }
    : due.length
      ? { title: due.length === 1 ? `Pay invoice ${due[0]!.invoice_number}` : `Pay ${due.length} invoices`, note: `${money(due.reduce((s, i) => s + i.balance_cents, 0), { cents: true })} due: ${due.map((i) => i.vehicle_name).join(', ')}. Pay by card or pre-authorized debit.`, href: due.length === 1 ? `/owner/invoices/${due[0]!.invoice_number}` : '/owner/invoices', cta: due.length === 1 ? 'Pay now' : 'See invoices' }
      : null;
  const fees = home.vehicles.reduce((s, v) => s + (v.status !== 'exited' && v.insurance_fee_cents ? v.insurance_fee_cents + (home.trackers_available ? v.tracker_fee_cents ?? 0 : 0) : 0), 0);
  const attention: ActionTileItem[] = [
    ...(!next && pending.length ? [{ key: 'processing', title: 'Your payment is processing', note: 'A pre-authorized debit takes 3 to 5 business days to clear. We email you when it does.', href: '/owner/invoices', cta: 'See invoices', testId: 'owner-next-step', icon: 'clock' as const }] : []),
    ...(home.vehicles.length && !home.payout_accounts.length ? [{ key: 'payout', title: 'Add the bank account we pay you into', note: 'Payouts need it.', href: '/owner/banking', cta: 'Banking', icon: 'bank' as const, urgent: true }] : []),
    ...(home.auto_debit.enabled && !home.auto_debit.mandate && !home.auto_debit.pending_setup && home.invoices.some((i) => i.payable)
      ? [{ key: 'debit', title: 'Set up a pre-authorized debit', note: 'Your fees are debited automatically once it is set up.', href: '/owner/banking', cta: 'Banking', testId: 'owner-debit-missing', icon: 'pay' as const }] : [])
  ];
  const open = home.invoices.filter((i) => i.status !== 'paid');
  const { months, live, photo, bookings } = view;
  const now = months.find((m) => m.current);
  const prev = months[months.length - 2];
  const payout = nextPayout(home);
  const enrolled = home.vehicles.filter((v) => live[v.vehicle_id]?.key !== 'onboarding' && live[v.vehicle_id]?.key !== 'off');
  const onRent = enrolled.filter((v) => live[v.vehicle_id]?.key === 'on_rent').length;
  const coming = upcoming(bookings, new Date(), 6);
  const nextOf = (id: string) => upcoming(bookings.filter((b) => b.vehicle_id === id), new Date(), 1)[0] ?? null;
  const banners = (
    <>
      {sp.signed && <p className="alert alert--ok" role="status" data-testid="owner-signed-banner"><span className="alert__title">Signed</span><span>Thank you: your signature is recorded and CarmaCars countersigned. Your signed copies appear in Documents within a few minutes, and we email them to you.</span></p>}
      {sp.account && <p className="alert alert--ok" role="status" data-testid="owner-account-banner"><span className="alert__title">Your owner account is open</span><span>Add your first car whenever you are ready.</span></p>}
      {sp.applied && <p className="alert alert--ok" role="status"><span className="alert__title">Application received</span><span>We reply within 1 business day with the terms for each vehicle.</span></p>}
    </>
  );
  const kicker = partner ? `Partner portal · ${partner.partner_number}` : 'Owner portal';
  if (!home.vehicles.length) {
    return (
      <>
        {banners}
        <PageHeader kicker={kicker} title={`Hello, ${home.owner.first_name}`} />
        {appTask && <ApplicationTask t={appTask} />}
        {partner ? <div className="pt-empty" data-testid="partner-no-cars"><p className="d4">No cars yet</p><p className="muted">CarmaCars adds your cars once we agree which ones join. Questions? Reply to any of our emails.</p>{partner.agreement_status !== 'signed' && <Link prefetch={false} className="btn btn--primary" href="/owner/partner-agreement">Read and sign your partner agreement</Link>}</div>
          : <section className="pt-card pt-card--next" aria-labelledby="ow-first-car" data-testid="owner-first-car"><p className="pt-kicker">Next step</p><h2 className="d3" id="ow-first-car">Add your first car</h2>
              <p>Start with the VIN: we look the car up and fill in the details. Then choose how it will work and we reply within 1 business day with its terms.</p>
              <p><Link prefetch={false} className="btn btn--primary" href="/list-your-car/apply" data-testid="owner-add-first-car">Add your first car</Link></p></section>}
      </>
    );
  }
  const shown = home.vehicles.slice(0, 3);
  return (
    <>
      {banners}
      <PortalHero testId="owner-hero" titleId="ow-hello" kicker={kicker} title={`Hello, ${home.owner.first_name}`}
        lead={enrolled.length ? `${plural(onRent, 'car')} of ${enrolled.length} on rent right now.` : 'Your cars appear here as they join.'}
        stats={<>
          <StatCard label="Rental charges this month" value={now?.rental_cents ?? 0} format="money" testId="owner-month-rental"
            delta={prev && now ? <Delta now={now.rental_cents} before={prev.rental_cents} label={`vs ${prev.label.split(' ')[0]}`} /> : undefined} />
          <StatCard label="Next payout" value={payout.cents !== null ? payout.cents : day(payout.date)} format="cents" testId="owner-next-payout" sub={payout.cents !== null ? `On ${day(payout.date)}` : 'Amount on your statement'} />
          <StatCard label="Days rented this month" value={now?.days ?? 0} testId="owner-month-days" sub={<Sparkline values={months.map((m) => m.days)} className="ow-hero-spark" />} />
        </>}
        media={
          <ul className="ow-hero-cars" data-count={shown.length} aria-label="Your cars right now">
            {shown.map((v, i) => (
              <li key={v.vehicle_id} className="ow-hero-car">
                <Link prefetch={false} href={`/owner/vehicles/${v.vehicle_id}`} className="ow-hero-car__link">
                  <CarPhoto photo={photo[v.vehicle_id]} name={v.name} eager={i === 0} />
                  <span className="ow-hero-car__shade" aria-hidden="true" />
                  <span className={`pu-pill pu-pill--${live[v.vehicle_id]?.tone ?? 'muted'}`}>{live[v.vehicle_id]?.label}</span>
                  <span className="ow-hero-car__name">{v.name}<small>{v.plate ?? 'Plate to come'}</small></span>
                </Link>
              </li>
            ))}
            {home.vehicles.length > shown.length && <li className="ow-hero-more"><Link prefetch={false} href="/owner/vehicles">+{home.vehicles.length - shown.length} more</Link></li>}
          </ul>
        } />
      {appTask && <ApplicationTask t={appTask} />}
      {next && (
        <section className="pt-card pt-card--next pu-next" aria-labelledby="ow-next" data-testid="owner-next-step">
          <p className="pt-kicker">Next step</p>
          <h2 className="d3" id="ow-next">{next.title}</h2>
          <p>{next.note}</p>
          <p className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}><Link prefetch={false} className="btn btn--primary" href={next.href}>{next.cta}</Link>
            {next.href === '/owner/sign' && !partner && !previewOnly && <Link prefetch={false} className="btn btn--ghost" href="/owner/review" data-testid="owner-review-link">Review or correct your details</Link>}</p>
        </section>
      )}
      <ActionTiles items={attention} title={next ? 'Also needs you' : 'Needs your attention'} />
      <div className="pu-grid-2 pu-grid-2--wide">
        <OwnerMonths months={months} />
        <section className="stack" aria-labelledby="ow-money">
          <div className="row" style={{ justifyContent: 'space-between' }}><h2 className="pt-section-title" id="ow-money">Money</h2><Link prefetch={false} className="link small" href={partner ? '/owner/statements' : '/owner/invoices'}>{partner ? 'Statements' : 'Invoices'}, statements and payouts</Link></div>
          <div className="pu-stats ow-money-tiles">
            {partner && <StatCard card label="CarmaCars commission" value={`${(partner.commission_effective_bps / 100).toFixed(partner.commission_effective_bps % 100 ? 2 : 0)}%`} testId="partner-commission" />}
            <StatCard card label="Due now" value={due.reduce((s, i) => s + i.balance_cents, 0)} format="cents" testId="owner-due" />
            <StatCard card label="Fees each month, before HST" value={fees} format="money" />
            <StatCard card label={home.auto_debit.next_debit_on ? 'Next debit' : 'Next billing date'} testId="owner-next-debit"
              value={home.auto_debit.next_debit_on ? `${money(home.auto_debit.next_debit_cents, { cents: true })} on ${day(home.auto_debit.next_debit_on)}` : day(home.next_billing_date)} />
            <StatCard card label="Next payout date" value={day(home.next_payout_date)} />
          </div>
          {open.length > 0 && <InvoiceRows items={open.slice(0, 3)} />}
          {!home.trackers_available && home.tracker_pending.length > 0 && <p className="small muted">{TRACKER_LATER}</p>}
          <section className="pu-panel" aria-labelledby="ow-coming" data-testid="owner-coming-up">
            <div className="pu-panel__head"><h2 className="pu-title" id="ow-coming">Coming up</h2><Link prefetch={false} className="link small" href="/owner/bookings">All bookings</Link></div>
            {coming.length ? (
              <Timeline label="Bookings coming up">
                {coming.map((b) => (
                  <TimelineItem key={b.booking_id} date={b.pickup_at} dateLabel={when(b.pickup_at, false)} state={b.status === 'on_rent' ? 'now' : 'future'}
                    title={b.vehicle_name} amount={amountText(b, (c) => money(c))}
                    meta={<><span>{viewOf(b) === 'unavailable' ? 'Unavailable' : b.status === 'on_rent' ? 'On rent now' : 'Confirmed'}</span><span>{when(b.pickup_at)} to {when(b.return_at)}</span></>} />
                ))}
              </Timeline>
            ) : <p className="small muted">No bookings coming up yet.</p>}
          </section>
        </section>
      </div>
      <section className="stack" aria-labelledby="ow-cars">
        <div className="row" style={{ justifyContent: 'space-between' }}><h2 className="pt-section-title" id="ow-cars">Your vehicles ({home.vehicles.length})</h2>{!partner && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/list-your-car/apply">Add a vehicle</Link>}</div>
        <ul className="ow-cars">{home.vehicles.slice(0, 4).map((v) => <VehicleCard key={v.vehicle_id} v={v} compact trackers={home.trackers_available} photo={photo[v.vehicle_id]} live={live[v.vehicle_id]} month={carThisMonth(months, v.vehicle_id)} next={nextOf(v.vehicle_id)} />)}</ul>
        {home.vehicles.length > 4 && <p><Link prefetch={false} className="link" href="/owner/vehicles">All {home.vehicles.length} vehicles</Link></p>}
      </section>
    </>
  );
}
