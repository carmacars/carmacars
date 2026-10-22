import { money } from '@/lib/format';
import { day } from '@/features/owner/Blocks';
import { STATUS_LABEL, type OwnerHistory } from './model';

// The owner's view of a car's upkeep (migration 0089), read only: what is due, the tires on it, and every service with
// who paid. Under the owner agreement (11.1) the owner pays for maintenance and routine wear: what CarmaCars paid for
// them is deducted on their statement, and shows here with its amount.
export function ServiceHistory({ h }: { h: OwnerHistory }) {
  const due = h.items.filter((i) => i.status === 'overdue' || i.status === 'due_soon');
  return (
    <section className="pt-card" aria-labelledby="ow-svc" data-testid="owner-service">
      <h2 className="d4" id="ow-svc">Service and maintenance</h2>
      <p className="small muted">We track the oil changes, brakes, tires and inspections of your car and book them when due. You pay for maintenance (your agreement, 11.1): a service we pay for is deducted on your statement.</p>
      {h.tires && <p className="small">Tires on the car: <b>{h.tires.season}</b>{h.tires.tread_mm !== null ? `, ${h.tires.tread_mm} mm of tread` : ''}.</p>}
      {due.length > 0 && <ul className="small" data-testid="owner-service-due">{due.map((i) => <li key={i.label}><b>{i.label}</b>: {STATUS_LABEL[i.status].toLowerCase()}{i.detail ? ` (${i.detail})` : ''}</li>)}</ul>}
      {h.records.length ? (
        <ul className="ow-rows" data-testid="owner-service-history">{h.records.map((r, n) => (
          <li key={n}><span>{r.items ?? 'Service'}</span><span className="ow-amount">{r.billed_to_you_cents !== null ? money(r.billed_to_you_cents, { cents: true }) : ''}</span>
            <span className="ow-meta"><span>{day(r.done_on)}</span>{r.odometer_km ? <span>{r.odometer_km.toLocaleString('en-CA')} km</span> : null}{r.shop ? <span>{r.shop}</span> : null}<span>Paid by: {r.paid_by}</span></span></li>))}
        </ul>
      ) : <p className="muted small">No service recorded yet.</p>}
    </section>
  );
}
