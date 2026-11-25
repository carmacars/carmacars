import { money } from '@/lib/format';
import { day } from '@/features/owner/Blocks';
import { STATUS_LABEL, type OwnerHistory } from './model';
import { OwnerKm } from './OwnerKm';

// The owner's view of a car's upkeep (migration 0089), read only: what is due, the tires on it, and every service with
// who paid. Under the owner agreement (11.1) the owner pays for maintenance and routine wear: what CarmaCars paid for
// them is deducted on their statement, and shows here with its amount.
export function ServiceHistory({ h }: { h: OwnerHistory }) {
  const due = h.items.filter((i) => i.status === 'overdue' || i.status === 'due_soon');
  return (
    <section className="pt-card" aria-labelledby="ow-svc" data-testid="owner-service">
      <h2 className="d4" id="ow-svc">Service and maintenance</h2>
      <OwnerKm h={h} testId="owner-service-km" />
      <p className="small muted">We track the oil changes, brakes, tires and inspections of your car and book them when due. You pay for maintenance (your agreement, 11.1): a service we pay for is deducted on your statement.</p>
      {h.tires && <p className="small">Tires on the car: <b>{h.tires.season}</b>{h.tires.tread_mm !== null ? `, ${h.tires.tread_mm} mm of tread` : ''}.</p>}
      {due.length > 0 && <ul className="small" data-testid="owner-service-due">{due.map((i) => <li key={i.label}><b>{i.label}</b>: {STATUS_LABEL[i.status].toLowerCase()}{i.detail ? ` (${i.detail})` : ''}</li>)}</ul>}
      {h.records.length ? (
        <ul className="ow-rows" data-testid="owner-service-history">{h.records.map((r, n) => (
          <li key={n}><span>{r.items ?? 'Service'}</span><span className="ow-amount">{r.billed_to_you_cents !== null ? money(r.billed_to_you_cents, { cents: true }) : ''}</span>
            <span className="ow-meta"><span>{day(r.done_on)}</span>{r.odometer_km ? <span>{r.odometer_km.toLocaleString('en-CA')} km</span> : null}{r.shop ? <span>{r.shop}</span> : null}<span>Paid by: {r.paid_by}</span></span></li>))}
        </ul>
      ) : <p className="muted small">No service recorded yet.</p>}
      {/* r50 (4000): the monthly check-in visits of a long rental: the car's condition as we found it */}
      {(h.checkins?.length ?? 0) > 0 && <>
        <h3 className="d5" id="ow-ci">Check-in visits</h3>
        <ul className="ow-rows" aria-labelledby="ow-ci" data-testid="owner-checkins">{h.checkins!.map((c, n) => (
          <li key={n}><span>{c.summary}</span><span className="ow-amount" />
            <span className="ow-meta"><span>{day(c.done_on)}</span>{c.odometer_km ? <span>{c.odometer_km.toLocaleString('en-CA')} km</span> : null}{c.tread_mm !== null ? <span>Tread {c.tread_mm} mm</span> : null}{c.next_service ? <span>Next: {c.next_service}</span> : null}</span></li>))}
        </ul></>}
    </section>
  );
}
