import Link from '@/components/Link';
import type { SessionUser } from '@/lib/auth';
import { money } from '@/lib/format';
import { ownerRentalHistory } from '@/server/owner/data';
import { carText, earnedText, historyHref, pageCount, stateLabel, summaryText, torontoWhen, type HistoryQuery } from '@/features/owner/history';

// Cars > Bookings > Rental history (r44, 2830): every rental your cars have been on, oldest first (or newest first), one
// car or all, 50 a page. Only what an owner may see: no renter, payment, deposit or insurer details, and your earnings as
// your approved statements carried them.
export async function RentalHistory({ user, q }: { user: SessionUser; q: HistoryQuery }) {
  const h = await ownerRentalHistory(user, q).catch((e) => { console.error('owner rental history', e instanceof Error ? e.message : e); return null; });
  if (!h) return <section className="stack" id="rental-history" aria-labelledby="ow-rh"><h2 className="pt-section-title" id="ow-rh">Rental history</h2><p className="pt-empty muted">Your rental history could not be loaded just now. Try again in a moment.</p></section>;
  const pages = pageCount(h.count);
  const page = Math.min(q.page, pages);
  const first = h.count ? h.offset + 1 : 0;
  const last = h.offset + h.rows.length;
  return (
    <section className="stack" id="rental-history" aria-labelledby="ow-rh" data-testid="owner-rental-history">
      <h2 className="pt-section-title" id="ow-rh">Rental history</h2>
      <p className="small muted">Every rental your cars have been on. Your earnings are what your approved statements carried for each rental.</p>
      <dl className="pt-dl pt-dl--money" data-testid="owner-rental-history-totals">
        <div><dt>Rentals</dt><dd>{h.count}</dd></div>
        <div><dt>Rental days</dt><dd>{h.days}</dd></div>
        <div><dt>On your statements</dt><dd>{money(h.earned_cents, { cents: true })}</dd></div>
        <div><dt>Not yet on a statement</dt><dd>{h.not_on_statement}</dd></div>
      </dl>
      <p className="vh">{summaryText(h)}</p>
      <form method="get" action="/owner/vehicles#rental-history" className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'end' }}>
        <input type="hidden" name="tab" value="bookings" />
        {q.newest && <input type="hidden" name="order" value="newest" />}
        <div className="field"><label className="label" htmlFor="ow-rh-car">Car</label>
          <select className="select" id="ow-rh-car" name="car" defaultValue={q.car ?? ''}>
            <option value="">All cars</option>
            {h.cars.map((c) => <option key={c.vehicle_id} value={c.vehicle_id}>{carText({ car: c.name, plate: c.plate })}</option>)}
          </select></div>
        <button className="btn btn--ghost btn--sm" type="submit">Show</button>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={historyHref(q, { newest: !q.newest, page: 1 })} data-testid="owner-rental-history-order">{q.newest ? 'Oldest first' : 'Newest first'}</Link>
      </form>
      {h.rows.length ? <>
        <p className="small muted" aria-live="polite">Showing {first} to {last} of {h.count}, {q.newest ? 'newest' : 'oldest'} first.</p>
        <div className="table-scroll" tabIndex={0} role="region" aria-label="Rental history">
          <table className="ad-table ad-table--dense">
            <thead><tr><th scope="col">Booking</th><th scope="col">Car</th><th scope="col">Pickup</th><th scope="col">Return</th><th scope="col">Days</th><th scope="col">Status</th><th scope="col">Your earnings</th></tr></thead>
            <tbody>{h.rows.map((r) => (
              <tr key={`${r.booking_id}-${r.vehicle_id}`} data-testid="owner-rental-history-row" data-state={r.state}>
                <td>{r.booking_number ?? ''}</td>
                <td>{carText(r)}</td>
                <td>{torontoWhen(r.pickup_at)}</td>
                <td>{torontoWhen(r.return_at)}</td>
                <td className="num">{r.days}</td>
                <td>{stateLabel(r.state)}</td>
                <td className={r.earned_cents === null ? 'muted' : 'num'}>{earnedText(r)}</td>
              </tr>))}
            </tbody>
          </table>
        </div>
        {pages > 1 && <nav className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }} aria-label="Rental history pages">
          {page > 1 && <Link prefetch={false} className="btn btn--ghost btn--sm" href={historyHref(q, { page: page - 1 })}>Previous</Link>}
          <span className="small">Page {page} of {pages}</span>
          {page < pages && <Link prefetch={false} className="btn btn--ghost btn--sm" href={historyHref(q, { page: page + 1 })}>Next</Link>}
        </nav>}
      </> : <p className="pt-empty muted">{q.car ? 'No rentals on this car yet.' : 'No rentals on your cars yet.'}</p>}
      <p className="small muted">Times are Toronto time. A cancelled booking is listed only when a charge was kept, with your part of it. Renter details, payments and deposits stay with CarmaCars.</p>
    </section>
  );
}
