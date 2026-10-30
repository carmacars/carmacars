import Link from 'next/link';
import { InfoTip } from '@/components/InfoTip';
import type { ReactNode } from 'react';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { CarImage } from '@/components/Picture';
import type { Photo } from '@/lib/types';
import { AWAITING_SIGNATURE, STATUS, bookingPath, carName } from './status';
import type { BookingStatus, BookingSummary, Line, OfferLine } from './types';

// Server-rendered pieces of the portal. Money is shown exactly as the database stored it.
export function StatusBadge({ s, awaiting = false }: { s: BookingStatus; awaiting?: boolean }) {
  // a rental staff added by hand is confirmed before the renter signs (0051): awaiting signature until then
  if (awaiting && s === 'confirmed') return <span className="badge badge--red" data-testid="status-badge">{AWAITING_SIGNATURE.label}</span>;
  return <span className={`badge ${STATUS[s].badge}`} data-testid="status-badge">{STATUS[s].label}</span>;
}

export function Back({ href, children }: { href: string; children: ReactNode }) {
  return <Link className="pt-back" href={href}><span aria-hidden="true">←</span> {children}</Link>;
}

export function TripRow({ b, photo }: { b: BookingSummary; photo: Photo | null }) {
  return (
    <li>
      <Link className="pt-trip" href={bookingPath(b.booking_number)} data-testid="trip-row">
        <div className="pt-trip__img"><CarImage p={photo} alt="" sizes="104px" width={300} height={200} /></div>
        <div className="pt-trip__body">
          <div className="row" style={{ gap: 'var(--s-2)' }}><StatusBadge s={b.status} /><span className="xs muted">{b.booking_number}</span></div>
          <span className="pt-trip__name">{carName(b)}</span>
          <span className="pt-trip__meta">{when(b.pickup_at)} to {when(b.return_at)}</span>
        </div>
      </Link>
    </li>
  );
}

type AnyLine = Pick<Line, 'charge_type' | 'description' | 'amount_cents'> | OfferLine;
const label = (l: AnyLine) => String(('description' in l && l.description) || ('label' in l && l.label) || l.charge_type.replace(/_/g, ' ')).replace(/\s*\((daily|the daily)[^)]*\)$/, '');

export function PriceBreakdown({ lines, hst, total, totalLabel = 'Total due now', insurer, deposit }: { lines: AnyLine[]; hst: number; total: number; totalLabel?: string; insurer?: number; deposit?: number }) {
  return (
    <div className="stack">
      <dl className="pt-dl pt-dl--money" data-testid="price-breakdown">
        {lines.map((l, i) => <div key={i}><dt>{label(l)}</dt><dd>{money(l.amount_cents, { cents: true })}</dd></div>)}
        <div><dt>HST</dt><dd>{money(hst, { cents: true })}</dd></div>
        {insurer ? <div><dt>Billed to your insurer</dt><dd>{money(-insurer, { cents: true })}</dd></div> : null}
        <div><dt><b>{totalLabel}</b></dt><dd className="pt-total" data-testid="total-due">{money(total, { cents: true })}</dd></div>
      </dl>
      {deposit !== undefined && <p className="small muted">Refundable deposit of {money(deposit)} is taken at pickup, not today.</p>}
    </div>
  );
}

// a row's third value (Release 21b): the key of its "i" (src/features/info/text.ts)
export function Dl({ rows }: { rows: Array<[string, ReactNode] | [string, ReactNode, string]> }) {
  return <dl className="pt-dl">{rows.filter(([, v]) => v !== null && v !== undefined && v !== '').map(([k, v, info]) => <div key={k}><dt>{k}{info && <InfoTip k={info} topic={k} />}</dt><dd>{v}</dd></div>)}</dl>;
}

export const placeText = (place: string | null, method: string, pickup: boolean) =>
  `${place ?? 'Our location'}${pickup ? (method === 'delivered' ? ' (we deliver)' : '') : (method === 'picked_up' ? ' (we collect)' : '')}`;
