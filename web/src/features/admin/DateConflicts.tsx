import Link from '@/components/Link';
import { Badge, t } from './ui';

// Conflicting dates on one car (0284): what else is on this booking's car for overlapping dates, each with what it is,
// and whether it keeps this booking off the car. A placeholder (0283) never counts either way.
export interface Overlap {
  type: 'booking' | 'block' | 'turo_trip'; id: string; kind: 'booked' | 'request' | 'not_blocking' | 'placeholder' | 'block' | 'turo';
  holds: boolean; starts_at: string; ends_at: string | null; booking_number?: string; status?: string; renter?: string | null; reason?: string | null; note?: string | null;
}

const KIND: Record<Overlap['kind'], string> = {
  booked: 'Booked', request: 'Request or offer', not_blocking: 'Not blocking', placeholder: 'Placeholder', block: 'Block', turo: 'Turo trip'
};
const WHY: Record<Overlap['kind'], string> = {
  booked: 'Takes the car for these dates',
  request: 'Not booked yet: the first one confirmed takes the car, the other comes back to staff',
  not_blocking: 'Does not block the calendar',
  placeholder: 'Placeholder: never counts, never matched to a toll or ticket',
  block: 'The car is blocked',
  turo: 'On Turo for these dates'
};

/** The list: what keeps this booking off the car first, then the rest by date. */
export function DateConflicts({ items, base = '/admin/bookings', self }: { items: Overlap[]; base?: string; self?: { placeholder: boolean } }) {
  if (!items.length) return <p className="small muted">No other request, offer, booking or block overlaps these dates.</p>;
  const sorted = [...items].sort((a, b) => Number(b.holds) - Number(a.holds) || a.starts_at.localeCompare(b.starts_at));
  return (
    <>
      {self?.placeholder && <p className="small muted dc-lead">This booking is a placeholder: nothing below keeps it off the car, and it keeps nothing off.</p>}
      <ul className="ad-list dc-list" data-testid="date-conflicts">
        {sorted.map((c) => (
          <li key={`${c.type}${c.id}`} className={`dc dc--${c.kind}${c.holds ? ' is-holding' : ''}`} data-kind={c.kind}>
            <span className="dc__what">
              <span className={`dc__kind dc__kind--${c.kind}`}>{KIND[c.kind]}</span>
              {c.booking_number ? <Link prefetch={false} className="link" href={`${base}/${encodeURIComponent(c.booking_number)}`}>{c.booking_number}</Link>
                : <b>{c.type === 'block' ? (c.reason ?? 'block').replace(/_/g, ' ').replace(/^./, (x) => x.toUpperCase()) : 'Turo'}</b>}
              {c.renter ? <span className="muted"> · {c.renter}</span> : null}
            </span>
            {c.status ? <Badge s={c.status} /> : <span />}
            <span className="ad-sub">{t(c.starts_at)}{c.ends_at ? ` to ${t(c.ends_at)}` : ', open-ended'} · <span className={c.holds ? 'ad-late' : undefined}>{WHY[c.kind]}</span></span>
          </li>
        ))}
      </ul>
    </>
  );
}

/** On a placeholder's page, instead of the next step: what it is, and the real rental on the car (0283). */
export function PlaceholderBanner({ p, items, base = '/admin/bookings' }: { p: { reason: string | null; by: string | null; at: string | null }; items: Overlap[]; base?: string }) {
  const real = items.filter((c) => c.type === 'booking' && c.kind === 'booked' && c.booking_number);
  return (
    <p className="alert ph-banner" role="note" data-testid="placeholder-banner">
      <span className="alert__title">Placeholder booking{p.reason ? `: ${p.reason}` : ''}</span>
      <span>It never blocks the calendar, is never handed over and sends the renter nothing. Tolls, tickets and damage go to the real rental
        {real.length ? <> ({real.map((c, i) => <span key={c.id}>{i ? ', ' : ''}<Link prefetch={false} className="link" href={`${base}/${encodeURIComponent(c.booking_number!)}`}>{c.booking_number}</Link></span>)})</> : null}.
        {' '}No commission, and not on the Live map.{p.by ? ` Marked by ${p.by}${p.at ? `, ${t(p.at)}` : ''}`.replace(/\.?$/, '.') : ''}</span>
    </p>
  );
}
