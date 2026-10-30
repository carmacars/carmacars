import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { $, Badge, Filters, PageHead, Table, t } from '@/features/admin/ui';
import { StatCard } from '@/components/portal-ui/StatCard';
import { WaitTimer } from '@/components/portal-ui/WaitTimer';
import { requestNow } from '@/features/va/lanes';
import { opensToYou, type ClaimInfo } from '@/features/offers/claim';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests', path: '/va/requests', noindex: true, description: 'Booking requests and offers out.' });

type Req = { id: string; booking_number: string; status: string; state: string; vehicle: string; renter: string; returning: boolean; pickup_at: string; return_at: string; days: number;
  total_cents: number; waiting_minutes: number; offer_expires_at: string | null; flags: string[];
  /** 0177: who is answering it now; when it opens to Sales (sales_waits: this person is Sales and it is not open to them yet) */
  claim?: ClaimInfo | null; sales_opens_at?: string | null; sales_waits?: boolean };

// The requests inbox (05-va.md section 4.1, 03-admin.md section 3): oldest first; each opens the review-and-offer screen.
export default async function VaRequests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user, aal }, sp] = await Promise.all([vaPage('/va/requests', ['cs', 'sales']), searchParams]);
  // the first reply target (Program settings, 5 minutes by default; 0057) marks a request waiting too long
  const [all, target] = await Promise.all([read<Req[]>('requests'), door<{ minutes: number; words: string }>(user.id, 'ops_read', 'reply_target', {}, aal).catch(() => ({ minutes: 5, words: '5 minutes' }))]);
  const state = sp.state ?? '';
  const now = requestNow();
  // the requests waiting for a first offer, the longest wait first; then the rest as the database ordered them
  const rows = all.filter((r) => !state || r.state === state).sort((a, b) => Number(b.status === 'requested') - Number(a.status === 'requested') || (a.status === 'requested' ? b.waiting_minutes - a.waiting_minutes : 0));
  const n = (st: string) => all.filter((r) => r.state === st).length;
  const waiting = all.filter((r) => r.status === 'requested');
  const late = waiting.filter((r) => r.waiting_minutes > target.minutes).length;
  return (
    <>
      <PageHead title="Requests" kicker={`${waiting.length} waiting · reply within ${target.words}`} purpose="Booking requests and offers out, the longest wait first. Open one to review it and send the offer.">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/va/offers/new" data-testid="send-offer-link">Send an offer without a request</Link></PageHead>
      <div className="va-strip" data-testid="requests-strip">
        <StatCard card label="Waiting for an offer" value={waiting.length} sub={`reply within ${target.words}`} />
        <StatCard card label={`Past ${target.minutes} minutes`} value={late} sub={late ? 'answer these first' : 'none late'} />
        <StatCard card label="Offers out" value={n('offer_out')} sub="waiting on the renter to accept" />
        <StatCard card label="Waiting for payment" value={n('awaiting_payment')} sub="accepted, not paid yet" />
        <StatCard card label="Offers expired" value={n('expired')} sub="re-send or close" />
      </div>
      <Filters base="/va/requests" name="state" value={state} sp={sp} options={[['', `All (${all.length})`], ['new', `New (${n('new')})`], ['waiting_on_renter', `Waiting on the renter (${n('waiting_on_renter')})`], ['pushed_back', `Pushed back (${n('pushed_back')})`], ['offer_out', `Offer out (${n('offer_out')})`], ['awaiting_payment', `Waiting for payment (${n('awaiting_payment')})`], ['expired', `Offer expired (${n('expired')})`]]} />
      <Table<Req> testId="requests" caption="Booking requests" rows={rows} empty={all.length ? 'No request in this state. Choose All to see every request.' : 'No requests waiting. New requests from the website appear here and on To do.'} cols={[
        { key: 'waiting', label: 'Waiting', render: (r) => <WaitTimer since={new Date(now - r.waiting_minutes * 60_000).toISOString()} targetMin={r.status === 'requested' ? target.minutes : undefined} bar={r.status === 'requested'} now={now} /> },
        { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(r.booking_number)}`}>{r.booking_number}</Link> },
        { key: 'state', label: 'State', className: 'wrap', render: (r) => <><Badge s={r.status}>{r.state === 'awaiting_payment' ? 'waiting for payment' : r.state.replace(/_/g, ' ')}</Badge>{r.status === 'requested' && (r.sales_waits || r.claim) && <span className="small" data-testid={`claim-${r.booking_number}`}> {r.sales_waits ? opensToYou(r.sales_opens_at) : r.claim!.mine ? 'You are answering it' : r.claim!.text}</span>}</> }, { key: 'vehicle', label: 'Car' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) },
        { key: 'renter', label: 'Renter', render: (r) => <>{r.renter} <span className="muted small">{r.returning ? 'returning' : 'new'}</span></> },
        { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
        { key: 'flags', label: 'Flags', className: 'wrap', render: (r) => r.flags.map((f) => <span key={f} className="ad-flag">{f}</span>) },
        { key: 'act', label: 'Action', render: (r) => { const free = r.status === 'requested' && !r.sales_waits && !(r.claim && !r.claim.mine);
          return <Link prefetch={false} className={`btn btn--sm ${free ? 'btn--primary' : 'btn--ghost'}`} href={`/va/bookings/${encodeURIComponent(r.booking_number)}`}>{free ? 'Review and offer' : 'Open'}</Link>; } }]} />
    </>
  );
}
