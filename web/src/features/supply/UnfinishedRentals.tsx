import Link from 'next/link';
import type { DraftRow } from '@/server/actions/supply';

const when = (iso: string) => new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

/** Unfinished rentals (0145): the drafts saved as they were typed, everyone's, newest first; each opens where it was left. */
export function UnfinishedRentals({ rows, base, current, title = 'Unfinished rentals' }: { rows: DraftRow[]; base: '/admin' | '/va' | '/field'; current?: string | null; title?: string }) {
  const list = rows.filter((r) => r.id !== current);
  if (!list.length) return null;
  return (
    <section className="pt-card ad-card stack" aria-labelledby="unfinished-h" data-testid="unfinished-rentals">
      <h2 className="d4" id="unfinished-h">{title} ({list.length})</h2>
      <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
        {list.map((r) => (
          <li key={r.id} className="row" data-testid="unfinished-row" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
            <span>
              <b>{r.title || r.vehicle || 'Not named yet'}</b>{r.quick ? <span className="badge" style={{ marginLeft: '.4rem' }}>Started at pickup</span> : null}
              <br /><span className="small muted">{r.mine ? 'You' : r.by ?? 'Someone'}, {when(r.updated_at)}{r.held_until ? `; the car is held until ${new Date(r.held_until).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' })}` : ''}
              {r.missing.length ? `; still missing: ${r.missing.join(', ')}` : '; ready to add'}</span>
            </span>
            <Link prefetch={false} className="btn btn--ghost btn--sm" href={r.kind === 'offer' ? `${base}/offers/new?draft=${r.id}` : `${base === '/field' ? '/field/rentals' : `${base}/bookings`}/new?draft=${r.id}`}>{r.kind === 'offer' ? 'Open the offer' : 'Finish it'}</Link>
          </li>))}
      </ul>
    </section>
  );
}
