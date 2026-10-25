import Link from 'next/link';
import { money, pct } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { CarImage } from '@/components/Picture';
import { DocumentList, DocumentRow, PuIcon } from '@/components/portal-ui';
import type { Photo } from '@/lib/types';
import type { Live, MonthCar } from './insights';
import { debitLine, invoiceStatus, invoiceTitle, MODE_LABEL, ONBOARDING_STATUS, type ChecklistItem, type OwnerBooking, type OwnerInvoiceRow, type OwnerVehicle } from './types';

// Server-rendered pieces of the owner portal. Money is shown exactly as the database stored it.
export const day = (iso: string | null | undefined) => (iso ? when(`${iso.slice(0, 10)}T12:00:00Z`, false) : '');
export const monthOf = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`)) : '');
export const invoicePath = (n: string) => `/owner/invoices/${encodeURIComponent(n)}`;

const WAITS: Record<string, string> = { owner: 'Waiting on you', carmacars: 'With our team', field: 'With our field team', fleet: 'With our fleet team' };

export function Checklist({ items: all, trackers = true }: { items: ChecklistItem[]; trackers?: boolean }) {
  const items = trackers ? all : all.filter((c) => c.code !== 'tracker_install');
  const firstOpen = items.findIndex((c) => c.status === 'open');
  return (
    <ol className="pt-steps" aria-label="Onboarding checklist">
      {items.map((c, i) => (
        <li key={c.code} className={c.status === 'done' ? 'is-done' : c.status === 'not_applicable' ? 'is-na' : ''}>
          <span>{c.label}{i === firstOpen && c.waits_on && <small>{WAITS[c.waits_on] ?? c.waits_on}</small>}{c.status === 'not_applicable' && <span className="vh"> (not needed)</span>}</span>
        </li>
      ))}
    </ol>
  );
}

/** The car's photo, or a quiet dark panel with its name when it has none yet. */
export function CarPhoto({ photo, name, eager = false }: { photo: Photo | null | undefined; name: string; eager?: boolean }) {
  return photo ? <CarImage p={photo} alt="" sizes="(min-width: 64rem) 30vw, 100vw" width={900} height={600} eager={eager} />
    : <span className="ow-photo-none" aria-hidden="true"><PuIcon name="car" /><span>{name}</span></span>;
}

export interface CarExtras { photo?: Photo | null; live?: Live; month?: MonthCar | null; next?: OwnerBooking | null }

export function VehicleCard({ v, compact = false, trackers = true, photo, live, month, next }: { v: OwnerVehicle; compact?: boolean; trackers?: boolean } & CarExtras) {
  const status = v.onboarding_status && v.onboarding_status !== 'enrolled' ? ONBOARDING_STATUS[v.onboarding_status] ?? v.onboarding_status : v.status.replace(/_/g, ' ');
  const enrolled = live && live.key !== 'onboarding';
  return (
    <li className="pu-car ow-car" data-testid="owner-vehicle" data-live={live?.key}>
      <div className="pu-car__media">
        <CarPhoto photo={photo} name={v.name} />
        <span className={`pu-pill pu-pill--${live?.tone ?? 'muted'} pu-car__pill`} data-testid="vehicle-live">{live?.label ?? status}</span>
      </div>
      <div className="pu-car__body">
        <div className="ow-car__head">
          <h3 className="ow-car__name"><Link href={`/owner/vehicles/${v.vehicle_id}`} className="pu-car__link">{v.name}</Link></h3>
          {live?.key === 'onboarding' && <span className="badge badge--outline">{status}</span>}
        </div>
        <p className="small muted">{[v.plate, MODE_LABEL[v.management_mode] ?? v.management_mode, v.insurance_fee_cents !== null ? (trackers ? `${money(v.insurance_fee_cents)} insurance, ${money(v.tracker_fee_cents)} tracker a month` : `${money(v.insurance_fee_cents)} insurance a month`) : null, v.revenue_share_bps !== null && v.management_mode !== 'self_managed' ? `${pct(v.revenue_share_bps)} Revenue Share` : null].filter(Boolean).join(' · ')}</p>
        {enrolled && month && (
          <dl className="pu-car__stats" aria-label="This month">
            <div><dt>Days rented</dt><dd>{month.days}</dd></div>
            <div><dt>Bookings</dt><dd>{month.bookings}</dd></div>
            <div><dt>Rental charges</dt><dd>{money(month.rental_cents)}</dd></div>
          </dl>
        )}
        {enrolled && next !== undefined && <p className="pu-car__next small">{next ? <><PuIcon name="clock" /><span>{next.status === 'on_rent' ? 'On rent until' : 'Next booking'} <b>{when(next.status === 'on_rent' ? next.return_at : next.pickup_at)}</b></span></> : <span className="muted">No booking coming up</span>}</p>}
        {v.next && (
          <div className={`ow-car__next${v.next.waits_on === 'owner' ? '' : ' is-ours'}`}>
            <b>{v.next.waits_on === 'owner' ? 'Your next step' : 'Next step'}: {v.next.item}</b>
            {v.next.action && <span>{v.next.action}</span>}
            <span className="xs muted">{WAITS[v.next.waits_on] ?? v.next.waits_on}</span>
          </div>
        )}
        {!compact && v.checklist && <Checklist items={v.checklist} trackers={trackers} />}
        {compact && v.checklist && <p className="small pu-car__more"><Link href={`/owner/vehicles/${v.vehicle_id}`}>Every step for this vehicle</Link></p>}
      </div>
    </li>
  );
}

export function InvoiceRows({ items, empty = 'No invoices yet.' }: { items: OwnerInvoiceRow[]; empty?: string }) {
  if (!items.length) return <p className="pt-empty muted">{empty}</p>;
  return (
    <DocumentList testId="invoice-rows" label="Invoices">
      {items.map((i) => {
        const s = invoiceStatus(i);
        const debit = debitLine(i.debit, day, (c) => money(c, { cents: true }));
        return (
          <DocumentRow key={i.id} testId="invoice-row" dataAttrs={{ 'data-invoice': i.invoice_number }} href={invoicePath(i.invoice_number)} badge="INV" accent={i.payable}
            title={`${i.invoice_number} · ${invoiceTitle(i, monthOf)}`}
            meta={<><span>{i.vehicle_name}</span><span>Issued {day(i.billing_date)}</span>{debit && <span data-testid="invoice-debit">{debit}</span>}</>}
            amount={money(i.total_cents, { cents: true })}
            status={<span className={`badge ${s.badge}`} data-testid="invoice-status">{s.label}</span>}
            action={i.payable ? <Link className="btn btn--primary btn--sm" href={invoicePath(i.invoice_number)}>Pay now</Link> : undefined} />
        );
      })}
    </DocumentList>
  );
}
