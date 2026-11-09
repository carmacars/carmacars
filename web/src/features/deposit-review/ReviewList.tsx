import Link from '@/components/Link';
import { Badge, Card, PageHead, Table, Tabs, d, t } from '@/features/admin/ui';
import { stageWords, sweepDays, type ListRow, type ReviewList as Data } from './model';

// The deposit reviews (release 35 part RR, migration 1010): Fleet's list (returns to check), Finance's (to double-check),
// the sweep (every plate returned since the last sweep and every booking still inside the toll and ticket window, with the
// toll operator and every ticket place one tap away), and the reviews done in the last 30 days. The same page in the Admin
// portal and the Fleet and Finance staff portals.
export function ReviewList({ d: v, base, bookingBase }: { d: Data; base: string; bookingBase: string }) {
  const href = (n: string) => `${bookingBase}/${encodeURIComponent(n)}/deposit-review`;
  const views: Array<[string, string]> = [[`${base}?view=open`, 'Open'], [`${base}?view=fleet`, 'Fleet to check'], [`${base}?view=finance`, 'Finance to double-check'],
    [`${base}?view=sweep`, 'This sweep'], [`${base}?view=done`, 'Done (30 days)']];
  return (
    <>
      <PageHead title="Deposit reviews" purpose={`Before a deposit is released: Fleet checks each return against its pickup, then Finance double-checks, checks the tolls and every ticket place. The sweep is ${sweepDays(v.sweep_days)}.`} />
      <Tabs items={views} current={`${base}?view=${v.view}`} label="Deposit reviews" />
      {v.view === 'sweep' ? (
        <div className="stack">
          <Card title="Where to check" testId="dr-sweep-links">
            <p className="small">{v.last_sweep ? `Last sweep ${d(v.last_sweep.run_on)}: ${v.last_sweep.cars} ${v.last_sweep.cars === 1 ? 'car' : 'cars'}.` : 'No sweep yet.'} Search each plate below for its dates, then record what you found on each booking&apos;s review.</p>
            <ul className="small" data-testid="dr-sweep-places">
              <li><a className="link" href={v.toll_url} target="_blank" rel="noreferrer">Highway tolls</a></li>
              {v.places.map((p) => <li key={p.key}><a className="link" href={p.url} target="_blank" rel="noreferrer">{p.name}</a></li>)}
            </ul>
          </Card>
          <Card title="Plates to check" testId="dr-sweep">
            {(v.sweep ?? []).length === 0 ? <p className="pt-empty">Nothing to check: no returns since the last sweep and nothing inside the toll and ticket window.</p> : (
              <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
                {(v.sweep ?? []).map((p) => (
                  <li key={p.plate} data-testid={`dr-plate-${p.plate}`}><b>{p.plate}</b> <span className="muted small">{p.vehicle}</span>
                    <ul className="small">{p.bookings.map((b) => <li key={b.booking_number}><Link prefetch={false} className="link" href={href(b.booking_number)}>{b.booking_number}</Link> back {t(b.returned_at)}{b.new ? ' · new since the last sweep' : ''}{b.in_window ? ' · inside the toll and ticket window' : ''} · {b.stage === 'done' ? 'review done' : b.stage === 'finance' ? 'Finance to double-check' : 'Fleet to check'}</li>)}</ul>
                  </li>))}
              </ul>)}
          </Card>
        </div>
      ) : (
        <Table<ListRow & Record<string, unknown>> testId="dr-list" rows={v.rows as Array<ListRow & Record<string, unknown>>} rowKey={(r) => r.booking_number} empty="Nothing waiting." cols={[
          { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={href(r.booking_number)}>{r.booking_number}</Link> },
          { key: 'plate', label: 'Car', render: (r) => `${r.plate ?? ''} ${r.vehicle}`.trim() },
          { key: 'renter', label: 'Renter' },
          { key: 'returned_at', label: 'Back', render: (r) => t(r.returned_at) },
          { key: 'state', label: 'Review', className: 'wrap', render: (r) => <span className="small">{stageWords(r.state)}</span> },
          { key: 'in_window', label: 'Toll window', render: (r) => (r.in_window ? 'open' : 'closed') },
          { key: 'deposit_status', label: 'Deposit', render: (r) => (r.deposit_status ? <Badge s={r.deposit_status} /> : '') }]} />
      )}
    </>
  );
}
