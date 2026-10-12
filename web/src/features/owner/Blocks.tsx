import Link from 'next/link';
import { money, pct } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { invoiceStatus, MODE_LABEL, ONBOARDING_STATUS, type ChecklistItem, type OwnerInvoiceRow, type OwnerVehicle } from './types';

// Server-rendered pieces of the owner portal. Money is shown exactly as the database stored it.
export const day = (iso: string | null | undefined) => (iso ? when(`${iso.slice(0, 10)}T12:00:00Z`, false) : '');
export const monthOf = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`)) : '');
export const invoicePath = (n: string) => `/owner/invoices/${encodeURIComponent(n)}`;

const WAITS: Record<string, string> = { owner: 'Waiting on you', carmacars: 'With our team', field: 'With our field team', fleet: 'With our fleet team' };

export function Checklist({ items }: { items: ChecklistItem[] }) {
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

export function VehicleCard({ v, compact = false }: { v: OwnerVehicle; compact?: boolean }) {
  const status = v.onboarding_status && v.onboarding_status !== 'enrolled' ? ONBOARDING_STATUS[v.onboarding_status] ?? v.onboarding_status : v.status.replace(/_/g, ' ');
  return (
    <li className="ow-car" data-testid="owner-vehicle">
      <div className="ow-car__head">
        <h3 className="ow-car__name"><Link href={`/owner/vehicles/${v.vehicle_id}`}>{v.name}</Link></h3>
        <span className="badge badge--outline">{status}</span>
      </div>
      <p className="small muted">{[v.plate, MODE_LABEL[v.management_mode] ?? v.management_mode, v.insurance_fee_cents !== null ? `${money(v.insurance_fee_cents)} insurance, ${money(v.tracker_fee_cents)} tracker a month` : null, v.revenue_share_bps !== null && v.management_mode !== 'self_managed' ? `${pct(v.revenue_share_bps)} Revenue Share` : null].filter(Boolean).join(' · ')}</p>
      {v.next && (
        <div className={`ow-car__next${v.next.waits_on === 'owner' ? '' : ' is-ours'}`}>
          <b>{v.next.waits_on === 'owner' ? 'Your next step' : 'Next step'}: {v.next.item}</b>
          {v.next.action && <span>{v.next.action}</span>}
          <span className="xs muted">{WAITS[v.next.waits_on] ?? v.next.waits_on}</span>
        </div>
      )}
      {!compact && v.checklist && <Checklist items={v.checklist} />}
      {compact && v.checklist && <p className="small"><Link href={`/owner/vehicles/${v.vehicle_id}`}>Every step for this vehicle</Link></p>}
    </li>
  );
}

export function InvoiceRows({ items, empty = 'No invoices yet.' }: { items: OwnerInvoiceRow[]; empty?: string }) {
  if (!items.length) return <p className="pt-empty muted">{empty}</p>;
  return (
    <ul className="ow-rows" data-testid="invoice-rows">
      {items.map((i) => {
        const s = invoiceStatus(i);
        return (
          <li key={i.id} data-testid="invoice-row" data-invoice={i.invoice_number}>
            <Link className="ow-row-link" href={invoicePath(i.invoice_number)}>{i.invoice_number} · {i.kind === 'upfront' ? 'Upfront invoice' : `Fees for ${monthOf(i.period_month)}`}</Link>
            <span className="ow-amount">{money(i.total_cents, { cents: true })}</span>
            <span className="ow-meta"><span>{i.vehicle_name}</span><span>Issued {day(i.billing_date)}</span><span className={`badge ${s.badge}`} data-testid="invoice-status">{s.label}</span>
              {i.payable && <Link className="btn btn--primary btn--sm" href={invoicePath(i.invoice_number)}>Pay now</Link>}</span>
          </li>
        );
      })}
    </ul>
  );
}

export function NotOwner() {
  return (
    <div className="pt-empty">
      <h1 className="d3">No owner account here yet</h1>
      <p className="muted">This sign-in is not linked to a car owner. Apply to list your car, or sign in with the email you applied with.</p>
      <p className="row" style={{ justifyContent: 'center' }}><Link className="btn btn--primary" href="/list-your-car/apply">Apply to list your car</Link><Link className="btn btn--ghost" href="/account">Go to your trips</Link></p>
    </div>
  );
}
