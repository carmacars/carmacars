import Link from '@/components/Link';
import { money } from '@/lib/format';
import { day } from './Blocks';
import type { FleetLeaseView } from './types';

// The fleet supplier's lease in the owner portal (migration 0710): each car, its tier and lease a month, when it went on
// the lease and the next payment date (in arrears, on the 10th, with the owner payouts). The supplier pays CarmaCars no
// fees: there are no invoices or debits. The statements show each payment line.
export function FleetLeaseCard({ lease }: { lease: FleetLeaseView }) {
  const monthly = lease.cars.filter((c) => c.status === 'on_lease').reduce((s, c) => s + (c.monthly_cents ?? 0), 0);
  return (
    <section className="pu-panel" aria-labelledby="ow-fleet" data-testid="owner-fleet-lease">
      <div className="pu-panel__head"><h2 className="pu-title" id="ow-fleet">Your fleet lease</h2><Link prefetch={false} className="link small" href="/owner/money">Statements</Link></div>
      <p className="small">
        {lease.cars.some((c) => c.status === 'on_lease') ? <>CarmaCars leases {lease.cars.filter((c) => c.status === 'on_lease').length} of your cars for <b>{money(monthly)}</b> a month in all. </> : null}
        {lease.next_payment_on ? <>Next payment: <b data-testid="owner-fleet-next">{day(lease.next_payment_on)}</b>, for the month before. </> : null}
        You pay CarmaCars no fees: no invoices, no debits.
      </p>
      {lease.cars.length ? (
        <div className="table-scroll"><table className="pu-table" data-testid="owner-fleet-cars">
          <thead><tr><th scope="col">Car</th><th scope="col">Tier</th><th scope="col">Lease a month</th><th scope="col">On the lease since</th><th scope="col">Next payment</th></tr></thead>
          <tbody>{lease.cars.map((c) => (
            <tr key={c.vehicle_id}>
              <td><Link prefetch={false} className="link" href={`/owner/vehicles/${c.vehicle_id}`}>{c.name}</Link>{c.plate ? <small className="muted"> · {c.plate}</small> : null}</td>
              <td>{c.tier === 'troubled' ? 'Troubled' : c.tier === 'regular' ? 'Regular' : '-'}</td>
              <td>{c.monthly_cents !== null ? money(c.monthly_cents) : '-'}</td>
              <td>{c.delivered_on ? day(c.delivered_on) : <span className="muted">Waiting for our check</span>}</td>
              <td>{c.next_payment_on ? day(c.next_payment_on) : '-'}</td>
            </tr>))}</tbody>
        </table></div>
      ) : <p className="small muted">No car yet. <Link prefetch={false} className="link" href="/list-your-car/apply">Add a car</Link>.</p>}
      <p className="small muted">The tier of each car is set when you add it and does not change. Part months are paid by the day. The ServiceOntario forms each car needs (the lease to CarmaCars, and the transfer into your corporation when it is not registered to it yet) are filled in for you: <Link prefetch={false} className="link" href="/owner/documents">Documents</Link>.</p>
    </section>
  );
}
