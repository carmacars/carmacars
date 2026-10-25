import { fmtDay, m, pc, sinceLine, type CarTermsData, type CarTermsRow } from './terms-shared';
import './car-terms.css';

// The owner portal's view of their terms (migration 0135): which terms apply to which car and from when, what is
// coming, and every change with its written notice. Read only: the owner agrees changes with CarmaCars.
const STATE: Record<string, string> = { not_set: 'Being set', pending: 'To sign', signed: 'Signed', fixed: 'Fixed' };
const STATUS: Record<string, string> = { applied: 'In place', noticed: 'Notice given', awaiting_signature: 'Waiting for your signature', cancelled: 'Cancelled' };

/** Every car: the terms in force, since when, and the next change. */
export function OwnerTermsSummary({ data }: { data: CarTermsData }) {
  if (!data.cars.length) return null;
  return (
    <section className="pt-card stack ct" aria-labelledby="ow-terms-h" data-testid="owner-terms">
      <h2 className="d4" id="ow-terms-h">Your terms, car by car</h2>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Your terms, car by car">
        <table className="ad-table ad-table--dense ad-table--cards ct-table">
          <thead><tr><th scope="col">Car</th><th scope="col" className="num">Insurance fee a month</th><th scope="col" className="num">Tracker fee a month</th>
            <th scope="col" className="num">Revenue Share</th><th scope="col">Since</th><th scope="col">Coming</th></tr></thead>
          <tbody>{data.cars.map((c) => (
            <tr key={c.vehicle_id} data-testid="owner-terms-row">
              <th scope="row" data-label="Car"><a className="link" href={`/owner/vehicles/${c.vehicle_id}#ow-terms`}><b>{c.name}</b></a><span className="small ct-state">{STATE[c.state] ?? c.state}{c.schedule_number ? `, ${c.schedule_number}` : ''}</span></th>
              <td data-label="Insurance fee a month" className="num">{m(c.current.insurance_fee_cents)}</td>
              <td data-label="Tracker fee a month" className="num">{m(c.current.tracker_fee_cents)}</td>
              <td data-label="Revenue Share" className="num">{pc(c.current.revenue_share_bps)}</td>
              <td data-label="Since">{sinceLine(c)}</td>
              <td data-label="Coming">{next(c)}</td>
            </tr>))}</tbody>
        </table>
      </div>
      <p className="small muted">Lower amounts apply from the date in our notice. A higher fee comes with {data.notice_days} days&apos; written notice; a higher Revenue Share only once you sign an updated Vehicle Schedule.</p>
    </section>
  );
}

function next(c: CarTermsRow) {
  if (c.awaiting) return <a className="link" href={`/owner/sign/schedule/${c.awaiting.change_id}`}>Updated Vehicle Schedule to sign (from {fmtDay(c.awaiting.effective_from)})</a>;
  const f = c.scheduled[0];
  if (!f) return 'Nothing';
  return `From ${fmtDay(f.from)}: ${m(f.insurance_fee_cents)} insurance, ${m(f.tracker_fee_cents)} tracker, ${pc(f.revenue_share_bps)}`;
}

/** One car: in force, coming, every period and every notice. */
export function OwnerTermsHistory({ car }: { car: CarTermsRow }) {
  return (
    <div className="stack ct" data-testid="owner-terms-history">
      <p className="small"><b>In force:</b> {m(car.current.insurance_fee_cents)} insurance and {m(car.current.tracker_fee_cents)} tracker a month, {pc(car.current.revenue_share_bps)} Revenue Share, since {sinceLine(car).replace(/^From/, 'from')}.</p>
      {car.awaiting && <p className="small">An updated Vehicle Schedule (from {fmtDay(car.awaiting.effective_from)}) is waiting for your signature. <a className="link" href={`/owner/sign/schedule/${car.awaiting.change_id}`}>Read and sign it</a></p>}
      {car.scheduled.map((p, i) => <p key={i} className="small" data-testid="owner-terms-coming"><b>From {fmtDay(p.from)}:</b> {m(p.insurance_fee_cents)} insurance, {m(p.tracker_fee_cents)} tracker, {pc(p.revenue_share_bps)} Revenue Share.</p>)}
      <details><summary className="link small">History</summary>
        <ul className="ct-periods">{car.periods.map((p, i) => (
          <li key={i} className={p.current ? 'is-current' : undefined}><span className="ct-when">{p.from ? `From ${fmtDay(p.from)}` : 'From the Enrollment Date'}{p.to ? ` to ${fmtDay(p.to)}` : ''}</span>
            <span className="small">{m(p.insurance_fee_cents)} insurance, {m(p.tracker_fee_cents)} tracker, {pc(p.revenue_share_bps)} Revenue Share</span></li>))}</ul>
        {car.changes.length > 0 && <ul className="ct-changes">{car.changes.map((x) => (
          <li key={x.id} data-testid="owner-terms-change"><span className="small"><b>{x.kind === 'decrease' ? 'Lower amounts' : x.kind === 'fee_notice' ? 'Fee change' : 'Updated Vehicle Schedule'}</b> · {STATUS[x.status] ?? x.status} · notice {fmtDay(x.notice_on)}, from {fmtDay(x.effective_from)}{x.reason ? `. ${x.reason}` : ''}</span>
            {x.notice && <a className="link small" href={`/files/terms_notice/${x.id}`} target="_blank" rel="noopener">Download the notice</a>}</li>))}</ul>}
      </details>
    </div>
  );
}
