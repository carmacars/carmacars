import { Act } from '@/features/admin/Act';
import { Card, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { holdLine, planSequence, STEP_LABEL, STOP_LABEL, type HoldItem, type Step } from './sequence';

// The booking page's review request card (migration 0146), the same for an Admin and an assistant: each step with when
// it went or when it will go (9 am to 9 pm), the hold and what is open, the stop and why, and "Ask for a review" (any
// booking on a trip, returned or closed), "Send anyway" (held), "Mark reviewed".
export interface ReviewPanelData {
  booking_id: string; booking_number: string; booking_status: string; owner_booking: boolean; enabled: boolean;
  status: 'waiting' | 'held' | 'asked' | 'finished' | 'stopped'; stop_reason: string | null; stopped_at: string | null;
  checkin_sent_at: string | null; ask_sent_at: string | null; reminder_sent_at: string | null; final_sent_at: string | null;
  manual_asks: number; last_manual_at: string | null; manual_pending: boolean;
  held: boolean; hold_items: HoldItem[]; held_since: string | null; send_anyway_at: string | null;
  returned_at: string | null; pickup_at: string; return_at: string; next: Step | null; next_at: string | null;
  helper_opened_at: string | null; google_opened_at: string | null; unhappy_at: string | null; may_ask: boolean; consent: boolean;
  onsite_review: { rating: number; status: string } | null; google_review: { rating: number | null; status: string; reviewer: string | null; at: string } | null;
  settings: { from_hour: number; until_hour: number; reminder_hours: number; final_days: number; ask_after_minutes: number; checkin_after_hours: number; checkin_min_days: number; checkin_enabled: boolean };
}

const d = (x: string | null | undefined) => (x ? new Date(x) : null);

export async function ReviewPanel({ booking, userId, aal, refresh }: { booking: string; userId: string; aal?: 'aal1' | 'aal2' | null; refresh: string[] }) {
  const r = await door<ReviewPanelData | null>(userId, 'ops_read', 'review_request', { booking }, aal).catch(() => null);
  if (!r || r.owner_booking || !['confirmed', 'on_rent', 'returned', 'closed'].includes(r.booking_status)) return null;
  const s = r.settings;
  const plan = planSequence({ pickupAt: new Date(r.pickup_at), returnAt: new Date(r.return_at), returnedAt: d(r.returned_at),
    sent: { checkin: d(r.checkin_sent_at), ask: d(r.ask_sent_at), reminder: d(r.reminder_sent_at), final: d(r.final_sent_at) } },
  { checkinEnabled: s.checkin_enabled, checkinMinDays: s.checkin_min_days, checkinAfterHours: s.checkin_after_hours, askAfterMinutes: s.ask_after_minutes,
    reminderHours: s.reminder_hours, finalDays: s.final_days, fromHour: s.from_hour, untilHour: s.until_hour });
  const stopped = r.status === 'stopped';
  const live = r.enabled && !stopped && r.status !== 'finished';
  const P = { booking: r.booking_number };
  return (
    <Card title="Review requests" testId="review-panel" tone={r.held ? 'warn' : undefined}
      aside={<span className="ad-actions">
        {r.may_ask && r.enabled && r.booking_status !== 'confirmed' && r.consent && (
          <Act ops action="review_ask_now" payload={P} label={r.held ? 'Ask anyway' : 'Ask for a review'} testId="review-ask-now" refresh={refresh}
            confirm={r.held ? 'Charges are still open on this booking. Ask the renter for a review anyway?' : `The review request goes now by email and text (from ${s.from_hour}:00 to ${s.until_hour}:00 Toronto time; later, at ${s.from_hour}:00).`}
            done="Review request on its way." />)}
        {r.held && <Act ops action="review_send_anyway" payload={P} label="Send anyway" variant="primary" testId="review-send-anyway" refresh={refresh}
          confirm="Release the hold: the review request and its follow-ups go even though a charge is still open." done="Released." />}
        {!stopped && ['on_rent', 'returned', 'closed'].includes(r.booking_status) && <Act ops action="review_mark_reviewed" payload={P} label="Mark reviewed" variant="quiet" testId="review-mark-reviewed" refresh={refresh}
          confirm="The renter reviewed us (on Google or elsewhere): no more review requests for this booking." done="No more requests." />}
      </span>}>
      <div className="stack">
        {!r.enabled && <p className="small muted">Review requests are off (Admin, Settings, Reviews).</p>}
        {stopped && <p data-testid="review-stopped"><b>Stopped:</b> {STOP_LABEL[r.stop_reason ?? ''] ?? r.stop_reason}{r.stopped_at ? `, ${t(r.stopped_at)}` : ''}.</p>}
        {r.held && <p className="ad-late" data-testid="review-held"><b>On hold</b> while charges are open: {holdLine(r.hold_items) || 'charges open'}. It goes by itself once they are settled or waived.</p>}
        {!r.consent && <p className="small" data-testid="review-no-consent">The renter unsubscribed from these messages: no review requests.</p>}
        {r.manual_pending && <p className="small">Asked by staff: goes at {r.next_at ? t(r.next_at) : `${s.from_hour}:00`}.</p>}
        <ol className="ad-timeline" data-testid="review-steps">
          {plan.map((p) => (
            <li key={p.step}><time>{p.sentAt ? t(p.sentAt.toISOString()) : ''}</time>
              <span><b>{STEP_LABEL[p.step]}</b>{' '}
                {p.sentAt ? 'sent' : p.skipped ? <span className="muted">({p.skipped})</span>
                  : !live || r.held && p.step !== 'checkin' ? <span className="muted">not sent</span>
                  : p.sendAt ? <span className="muted">due {t(p.sendAt.toISOString())}</span> : null}</span></li>
          ))}
        </ol>
        {(r.manual_asks > 0 || r.helper_opened_at || r.onsite_review || r.google_review) && (
          <p className="small">
            {r.manual_asks > 0 ? `Asked by staff ${r.manual_asks} ${r.manual_asks === 1 ? 'time' : 'times'}${r.last_manual_at ? `, last ${t(r.last_manual_at)}` : ''}. ` : ''}
            {r.helper_opened_at ? `The renter opened the review page ${t(r.helper_opened_at)}${r.google_opened_at ? ' and went on to Google' : ''}. ` : ''}
            {r.unhappy_at ? 'They pressed "Tell us directly". ' : ''}
            {r.onsite_review ? `Review on the site: ${r.onsite_review.rating} of 5 (${r.onsite_review.status}). ` : ''}
            {r.google_review ? `Google review: ${r.google_review.rating ?? '?'} of 5, ${r.google_review.status === 'suggested' ? 'a possible match to confirm in Reviews' : 'matched'}.` : ''}
          </p>)}
      </div>
    </Card>
  );
}
