import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { requireUser } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';
import { when } from '@/features/agreement/model';
import { DocumentList, DocumentRow, PortalCard } from '@/components/portal-ui';
import { AccidentSummary } from '@/features/accident-card/AccidentCard';
import { AccidentReport } from '@/features/accident-card/AccidentReport';
import { digitalView, incidentDocHref, incidentHref, proofWords, type IncidentDigital } from '@/features/incident-cards/digital';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Incident card', path: '/account/incident', noindex: true, description: 'Your digital incident card: what to do, your coverage, your booking and your rental agreement.' });

const tel = (p: string) => `tel:${p.replace(/[^\d+]/g, '')}`;

// The digital incident card (1150): the printed card's QR code (/incident) lands here after sign-in. The renter or a driver
// named on the booking in progress sees that booking: car, plate, dates, booking number, drivers, the coverage option with its
// proof, the rental agreement, the steps, the numbers and Report a problem. Several bookings in progress: pick one. None (or
// not a driver on any): the steps and the numbers only. The database returns only the person's own bookings.
export default async function IncidentCardPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const b = sp.b && /^[A-Z]{1,4}-[0-9A-Z]{1,12}$/.test(sp.b) ? sp.b : '';
  const user = await requireUser(b ? incidentHref(b) : incidentHref());
  const d = (await rpc('server_incident_digital', { p_by: user.id, p: { booking: b } }, { role: 'service_role' })) as unknown as IncidentDigital;
  const v = digitalView(d);
  const phone = d.company.support_phone;
  const road = d.company.roadside_phone;
  return (
    <div className="stack" data-testid="incident-digital">
      <h1 className="d3">Incident card</h1>
      <PortalCard id="ic-numbers" title="Call us" testId="incident-numbers">
        <p className="ad-actions">
          <a className="btn btn--primary btn--sm" href="tel:911">Someone is hurt: 911</a>
          {phone && <a className="btn btn--ghost btn--sm" href={tel(phone)} data-testid="incident-support">Support: {phone}</a>}
          {road && road !== phone && <a className="btn btn--ghost btn--sm" href={tel(road)} data-testid="incident-roadside">Roadside: {road}</a>}
        </p>
      </PortalCard>

      {v.mode === 'pick' && (
        <PortalCard id="ic-pick" title="Which booking?" testId="incident-pick">
          <ul className="stack">{v.bookings.map((x) => (
            <li key={x.booking_number}><Link prefetch={false} className="btn btn--ghost btn--sm" href={incidentHref(x.booking_number)} data-testid={`incident-pick-${x.booking_number}`}>
              {x.car ?? 'Car'}{x.plate ? `, plate ${x.plate}` : ''}: {x.booking_number}</Link></li>))}</ul>
        </PortalCard>
      )}

      {v.mode === 'card' && (() => {
        const c = v.card;
        const car = [c.car.year, c.car.make, c.car.model].filter(Boolean).join(' ') || 'Car';
        return (
          <>
            <PortalCard id="ic-booking" title="Your booking" testId="incident-booking"
              action={c.role === 'renter' ? <Link prefetch={false} className="btn btn--ghost btn--sm" href={bookingPath(c.booking_number)}>Open the booking</Link> : undefined}>
              <dl className="pt-dl">
                <div><dt>Car</dt><dd data-testid="incident-car">{car}</dd></div>
                <div><dt>Plate</dt><dd data-testid="incident-plate">{c.car.plate ?? 'n/a'}</dd></div>
                <div><dt>Booking</dt><dd data-testid="incident-booking-number">{c.booking_number}</dd></div>
                <div><dt>Pickup</dt><dd>{when(c.pickup_at)}</dd></div>
                <div><dt>Return</dt><dd>{when(c.return_at)}</dd></div>
                <div><dt>Drivers</dt><dd data-testid="incident-drivers">{c.drivers.map((x) => `${x.name}${x.role === 'renter' ? ' (renter)' : ''}`).join(', ') || 'n/a'}</dd></div>
              </dl>
              {v.others.length > 0 && <p className="small">Another booking in progress: {v.others.map((x) => <Link key={x.booking_number} prefetch={false} className="link" href={incidentHref(x.booking_number)}>{x.booking_number}</Link>)}</p>}
            </PortalCard>
            <PortalCard id="ic-coverage" title="Your coverage and what to show" testId="incident-coverage">
              <p data-testid="incident-show">{proofWords(c)}</p>
              <AccidentSummary d={c} />
            </PortalCard>
            <PortalCard id="ic-docs" title="Documents" testId="incident-docs">
              <DocumentList plain>
                {c.contract ? <DocumentRow badge="PDF" external title="Rental agreement" meta={when(c.contract.created_at, false)} href={incidentDocHref(c.contract.document_id)} linkTestId="incident-contract" />
                  : null}
                {c.proof ? <DocumentRow badge={c.proof.mime?.startsWith('image/') ? 'IMG' : 'PDF'} external title="Proof of coverage" href={incidentDocHref(c.proof.document_id)} linkTestId="incident-proof" /> : null}
              </DocumentList>
              {!c.contract && <p className="small muted">The rental agreement appears here once it is signed.</p>}
            </PortalCard>
            <PortalCard id="ic-report" title="Report a problem" testId="incident-report">
              {c.status === 'on_rent' ? <AccidentReport booking={c.booking_id} number={c.booking_number} phone={phone ?? null} />
                : <p className="small">Report it here once you have the car. Before then, call us{phone ? ` at ${phone}` : ''}.</p>}
            </PortalCard>
          </>
        );
      })()}

      {v.mode !== 'card' && (
        <PortalCard id="ic-steps" title="In an accident or breakdown" testId="incident-steps">
          <ol className="small">{v.steps.map((s) => <li key={s}>{s}</li>)}</ol>
          {v.mode === 'none' && <p className="small muted" data-testid="incident-no-booking">No booking in progress on your account. If you are driving one of our cars, sign in with the account named on the booking, or call us.</p>}
        </PortalCard>
      )}
    </div>
  );
}
