import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { $, ago, Badge, BookingLink, Filters, PageHead, Table, t } from '@/features/admin/ui';
import { LiveWait } from '@/features/admin/shell/LiveWait';
import type { ClaimInfo } from '@/features/offers/claim';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests', path: '/admin/requests', noindex: true, description: 'Booking requests, oldest first.' });

type Req = { id: string; booking_number: string; status: string; state: string; vehicle: string; renter: string; returning: boolean; pickup_at: string; return_at: string; days: number;
  total_cents: number; waiting_minutes: number; offer_expires_at: string | null; drivers: string[]; flags: string[]; assigned: string | null;
  /** 0177: who is answering it now, and when it opens to Sales */
  claim?: ClaimInfo | null; sales_opens_at?: string | null };
const STATES: Array<[string, string]> = [['', 'All'], ['new', 'New'], ['waiting_on_renter', 'Waiting on the renter'], ['pushed_back', 'Pushed back'], ['offer_out', 'Offer out'], ['awaiting_payment', 'Waiting for payment'], ['expired', 'Offer expired']];

// The request inbox (03-admin.md section 3): oldest first until each is offered or declined.
export default async function Requests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/requests'), searchParams]);
  // the first reply target (Program settings, 5 minutes by default; 0057) marks a request waiting too long
  const [all, target] = await Promise.all([read<Req[]>('requests'), door<{ minutes: number; words: string }>(user.id, 'ops_read', 'reply_target').catch(() => ({ minutes: 5, words: '5 minutes' }))]);
  const state = sp.state ?? '';
  const rows = all.filter((r) => !state || r.state === state);
  return (
    <>
      <PageHead title="Requests" kicker={`${all.filter((r) => r.status === 'requested').length} waiting · first reply target ${target.words}`} purpose="Oldest first. Open a booking number to price it and send the offer; the clock turns red past the reply target.">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/offers/new" data-testid="send-offer-link">Send an offer without a request</Link></PageHead>
      <Filters base="/admin/requests" name="state" value={state} options={STATES.map(([k, l]) => [k, `${l}${k ? ` (${all.filter((r) => r.state === k).length})` : ''}`])} sp={sp} />
      <Table<Req> testId="requests" caption="Booking requests" rows={rows} empty="No requests waiting. New booking requests from the website show up here to price and offer." cols={[
        // a request still waiting for its first answer keeps counting while the page is open, red past the reply target
        { key: 'waiting', label: 'Waiting', render: (r) => r.status === 'requested' ? <LiveWait key={`${r.id}-${r.waiting_minutes}`} minutes={r.waiting_minutes} target={target.minutes} /> : <span className="muted">{ago(r.waiting_minutes)}</span> },
        { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> },
        { key: 'state', label: 'State', className: 'wrap', render: (r) => <><Badge s={r.status}>{r.state === 'awaiting_payment' ? 'waiting for payment' : r.state.replace(/_/g, ' ')}</Badge>{r.claim && <span className="small" data-testid={`claim-${r.booking_number}`}> {r.claim.mine ? 'You are answering it' : r.claim.text}</span>}</> },
        { key: 'vehicle', label: 'Car' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) },
        { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) },
        { key: 'days', label: 'Days', num: true },
        { key: 'renter', label: 'Renter', render: (r) => <>{r.renter} <span className="muted small">{r.returning ? 'returning' : 'new'}</span></> },
        { key: 'drivers', label: 'Drivers', render: (r) => r.drivers.map((x) => x.replace(/_/g, ' ')).join(', ') },
        { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
        { key: 'flags', label: 'Flags', className: 'wrap', render: (r) => r.flags.map((f) => <span key={f} className={`ad-flag${['Conflict', 'Blocked renter', 'Under 21'].includes(f) ? ' ad-flag--red' : ''}`}>{f}</span>) },
        { key: 'assigned', label: 'Assigned' },
        { key: 'act', label: 'Actions', render: (r) => r.status === 'requested' && r.claim && !r.claim.mine ? <BookingLink n={r.booking_number} />
          : r.status === 'requested' ? <Act action="decline_request" payload={{ booking: r.id }} label="Decline" title={`Decline ${r.booking_number}`}
            fields={[{ name: 'note', label: 'Reason and any alternative', type: 'textarea', required: true }]} refresh={['/admin/requests']} />
          : r.status === 'expired' ? <Act action="reopen_expired" payload={{ booking: r.id }} label="Reopen" fields={[{ name: 'note', label: 'Note', type: 'text' }]} refresh={['/admin/requests']} /> : null }
      ]} />
    </>
  );
}
