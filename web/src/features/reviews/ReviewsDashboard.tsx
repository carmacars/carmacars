import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Card, Table, Tiles, t } from '@/features/admin/ui';
import { holdLine, type HoldItem } from './sequence';

// The review request program's numbers and lists (migration 0138): Admin > Reviews and customer service's Review
// requests. Requests sent, on hold, reviews detected, the average rating; the "Review requests on hold" list (released
// by itself when the charges are settled or waived, or Send anyway); the Google reviews and their matches to renters.
export interface Overview {
  days: number; enabled: boolean; google_url: string | null;
  sent: { checkin: number; ask: number; reminder: number; final: number; manual: number };
  on_hold: number;
  detected: { onsite: number; google: number; google_matched: number; renter_said: number; staff_marked: number };
  rating: { onsite_avg: number | null; onsite_n: number; google_avg: number | null; google_n: number; all_avg: number | null };
  held: Array<{ booking_id: string; booking_number: string; renter: string; vehicle: string; returned_at: string | null; held_since: string | null; reasons: string[]; items: HoldItem[] }>;
  google: { status: string; account_email: string | null; location_title: string | null; last_sync_at: string | null; last_ok_at: string | null; last_error: string | null };
  matches: Array<{ id: string; reviewer: string | null; rating: number | null; comment: string | null; reviewed_at: string; status: string; score: number | null; booking_id: string | null; booking_number: string | null; renter: string | null }>;
}
type Row = Record<string, unknown>;

const GOOGLE_STATUS: Record<string, string> = {
  not_connected: 'Google is not connected',
  connected: 'Google connected',
  api_not_approved: 'Google has not approved the Business Profile API for this project yet',
  error: 'The Google sync failed'
};
const avg = (x: number | null) => (x === null || x === undefined ? 'None yet' : Number(x).toFixed(1));

export function ReviewsDashboard({ o, base, bookingBase, admin, canMatch }: { o: Overview; base: string; bookingBase: string; admin: boolean; canMatch: boolean }) {
  const R = [base];
  const sent = o.sent.ask + o.sent.reminder + o.sent.final;
  const detected = o.detected.onsite + o.detected.google_matched + o.detected.renter_said + o.detected.staff_marked;
  return (
    <div className="stack" data-testid="reviews-dashboard">
      {!o.enabled && <p className="alert alert--warn" role="note"><span>Review requests are off.{admin ? <> Turn them on in <Link prefetch={false} className="link" href="/admin/settings/reviews">Settings, Reviews</Link>.</> : null}</span></p>}
      <Tiles items={[
        { k: `Requests sent, ${o.days} days`, v: String(sent), sub: `${o.sent.ask} requests, ${o.sent.reminder} reminders, ${o.sent.final} final; ${o.sent.checkin} check-ins` },
        { k: 'On hold', v: String(o.on_hold), sub: 'charges still open', warn: o.on_hold > 0 },
        { k: `Reviews detected, ${o.days} days`, v: String(detected), sub: `${o.detected.onsite} on the site, ${o.detected.google_matched} Google matched, ${o.detected.renter_said} said so, ${o.detected.staff_marked} marked` },
        { k: 'Average rating', v: avg(o.rating.all_avg), sub: `Google ${avg(o.rating.google_avg)} (${o.rating.google_n}), site ${avg(o.rating.onsite_avg)} (${o.rating.onsite_n})` }
      ]} />
      <Card title="Review requests on hold" testId="review-holds" tone={o.held.length ? 'warn' : undefined}>
        <p className="small muted">No review request goes while a return or later charge (late, kilometres, fuel, cleaning, smoking, damage, tolls) is open. Each booking leaves this list by itself once its charges are settled or waived.</p>
        <Table<Row> rows={o.held as unknown as Row[]} rowKey={(r) => String(r.booking_id)} empty="Nothing on hold." cols={[
          { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(String(r.booking_number))}`}>{String(r.booking_number)}</Link> },
          { key: 'renter', label: 'Renter' }, { key: 'vehicle', label: 'Car' },
          { key: 'items', label: 'Open', className: 'wrap', render: (r) => holdLine(r.items as HoldItem[]) },
          { key: 'held_since', label: 'Held since', render: (r) => t(r.held_since) },
          { key: 'act', label: '', render: (r) => <span className="ad-actions">
            <Act ops action="review_send_anyway" payload={{ booking: r.booking_number }} label="Send anyway" testId={`hold-send-${String(r.booking_number)}`} refresh={R}
              confirm="Release the hold: the review request and its follow-ups go even though a charge is still open." done="Released." />
            <Act ops action="review_mark_reviewed" payload={{ booking: r.booking_number }} label="Do not ask" variant="quiet" refresh={R}
              confirm="No review requests for this booking." done="Stopped." /></span> }]} />
      </Card>
      <Card title="Google reviews" testId="google-reviews"
        aside={admin ? <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/settings/reviews">Google connection</Link> : undefined}>
        <p className="small" data-testid="google-status">{GOOGLE_STATUS[o.google.status] ?? o.google.status}{o.google.location_title ? `: ${o.google.location_title}` : ''}
          {o.google.last_ok_at ? `. Last read ${t(o.google.last_ok_at)}` : ''}{o.google.last_error && o.google.status !== 'connected' ? `. ${o.google.last_error}` : ''}.
          {' '}A review is matched to a renter by name within the days after their return; a clear match stops their reminders, a possible one waits for you.</p>
        <Table<Row> rows={o.matches as unknown as Row[]} rowKey={(r) => String(r.id)} empty="No Google reviews read yet." cols={[
          { key: 'reviewed_at', label: 'Posted', render: (r) => t(r.reviewed_at) },
          { key: 'reviewer', label: 'Name on Google', render: (r) => String(r.reviewer ?? 'Anonymous') },
          { key: 'rating', label: 'Stars', num: true },
          { key: 'comment', label: 'Review', className: 'wrap', render: (r) => String(r.comment ?? '') },
          { key: 'status', label: 'Renter', render: (r) => r.booking_number
            ? <><Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(String(r.booking_number))}`}>{String(r.booking_number)}</Link> {String(r.renter ?? '')} <span className="muted small">({r.status === 'suggested' ? 'possible match' : String(r.status)})</span></>
            : <span className="muted">{r.status === 'rejected' ? 'not a renter' : 'no match'}</span> },
          { key: 'act', label: '', render: (r) => canMatch ? <span className="ad-actions">
            {r.status === 'suggested' && <Act ops action="review_google_match" payload={{ id: r.id, act: 'confirm' }} label="Confirm" variant="primary" refresh={R} done="Confirmed." />}
            {['suggested', 'matched', 'confirmed'].includes(String(r.status)) && <Act ops action="review_google_match" payload={{ id: r.id, act: 'reject' }} label="Not this renter" variant="quiet" refresh={R} done="Unmatched." />}
            <Act ops action="review_google_match" payload={{ id: r.id, act: 'assign' }} label="Match to a booking" variant="quiet" refresh={R} done="Matched."
              fields={[{ name: 'booking', label: 'Booking number', type: 'text', required: true, placeholder: 'CC-10482' }]} /></span> : null }]} />
      </Card>
    </div>
  );
}
