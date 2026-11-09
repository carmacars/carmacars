import Link from '@/components/Link';
import { $, PageHead, Table, t } from '@/features/admin/ui';
import { cardLabel } from '@/features/money/ledger';
import { UnlinkedAside } from './UnlinkedAside';

// Money > Unlinked Stripe (r35, migration 1081), for Admin and Finance: the succeeded Stripe charges of the last 60 days
// that no booking, payment link or owner debit knows, as the nightly check (from 3 a.m.) found them, with its best guess
// of the booking (the booking number Stripe kept, the renter's email, or a booking with that amount open). An Admin links
// one from the booking's Money tab (Link a payment taken outside the platform); one that is not a booking's payment is put
// aside with the reason.
export type UnlinkedRow = { charge_id: string; intent_id: string | null; amount_cents: number; refunded_cents: number; currency: string; charged_at: string;
  email: string | null; name: string | null; brand: string | null; last4: string | null; description: string | null;
  guess: { booking_number: string; reason: string | null; status: string; pickup_at: string } | null; dismissed_at: string | null; dismiss_note: string | null } & Record<string, unknown>;
export interface Unlinked { checked_at: string | null; check_ok: boolean | null; check_error: string | null; last_ok_at: string | null; open: number; rows: UnlinkedRow[] }

export function UnlinkedStripe({ u, bookingHref, all, base }: { u: Unlinked; bookingHref: (n: string) => string; all: boolean; base: string }) {
  const status = !u.checked_at ? 'Not checked yet: the first check runs tonight from 3 a.m.'
    : u.check_ok ? `Checked ${t(u.checked_at)}.` : `The last check could not read Stripe (${u.check_error ?? 'no answer'}), ${t(u.checked_at)}; it tries again within the hour.${u.last_ok_at ? ` Last complete check ${t(u.last_ok_at)}.` : ''}`;
  return (<>
    <PageHead title="Unlinked Stripe payments" kicker={`${u.open} to link`}
      purpose="Succeeded Stripe payments of the last 60 days that no booking knows: taken in the Stripe Dashboard or through a payment link. Open the guessed booking and use Link a payment taken outside the platform on its Money tab (an Admin), or put one aside when it is not a booking's payment." />
    <p className="small muted" data-testid="unlinked-status">{status} <Link prefetch={false} className="link" href={all ? base : `${base}&all=1`}>{all ? 'Hide the ones put aside' : 'Show the ones put aside'}</Link></p>
    <Table<UnlinkedRow> testId="unlinked-stripe" rows={u.rows} empty="Every Stripe payment of the last 60 days is linked to the platform."
      cols={[{ key: 'charged_at', label: 'Paid', render: (r) => t(r.charged_at) },
        { key: 'amount_cents', label: 'Amount', num: true, render: (r) => <>{$(r.amount_cents)}{r.currency !== 'cad' ? ` ${r.currency.toUpperCase()}` : ''}{r.refunded_cents ? <span className="small muted"> ({$(r.refunded_cents)} refunded)</span> : null}</> },
        { key: 'who', label: 'Paid by', className: 'wrap', render: (r) => [r.name, r.email].filter(Boolean).join(', ') },
        { key: 'card', label: 'Card', render: (r) => cardLabel(r.brand, r.last4) },
        { key: 'ids', label: 'Stripe id', render: (r) => <span className="pt-mono small">{r.intent_id ?? r.charge_id}</span> },
        { key: 'guess', label: 'Best guess', render: (r) => r.guess ? <><Link prefetch={false} className="link" href={bookingHref(r.guess.booking_number)}>{r.guess.booking_number}</Link><span className="small muted"> by {r.guess.reason ?? 'match'}</span></> : <span className="muted">none</span> },
        { key: 'act', label: '', render: (r) => <UnlinkedAside id={r.charge_id} aside={r.dismissed_at ? r.dismiss_note ?? 'put aside' : null} /> }]} />
  </>);
}
