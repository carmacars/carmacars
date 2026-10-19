import Link from 'next/link';
import { when } from '@/features/agreement/model';

// The renter's visits on the site (migration 0060), on the booking page and the renter page: when they viewed the
// offer, opened the change proposal, left the pay page, which cars they looked at, and their chats.
export interface TimelineData {
  events: Array<{ at: string; kind: string; page: string | null; path: string | null; car: string | null; booking_number: string | null; ms: number | null }>;
  chats: Array<{ id: string; number: string; status: string; at: string; messages: number }>;
  visits: number; last_seen_at: string | null; signals: Array<{ label: string; at: string }>;
}
const WORDS: Record<string, string> = {
  page_view: 'Viewed', car_view: 'Opened a car', search: 'Searched dates', request_started: 'Started a booking request', request_abandoned: 'Left the request form',
  request_submitted: 'Sent a booking request', email_link_opened: 'Opened an email link', offer_viewed: 'Viewed the offer', change_viewed: 'Opened the change proposal',
  pay_viewed: 'Viewed the pay page', pay_left: 'Left the pay page', chat_opened: 'Opened the chat'
};

export function VisitorTimeline({ t, chatBase }: { t: TimelineData | null; chatBase: string }) {
  if (!t) return <p className="small muted">Not available.</p>;
  if (!t.events.length && !t.chats.length) return <p className="small muted" data-testid="visitor-timeline-empty">No visit recorded. Visits are recorded when the renter accepts analytics, or on their own booking pages when signed in or arriving from one of our emails.</p>;
  return (
    <div className="stack" data-testid="visitor-timeline">
      <p className="small muted">{t.visits} visit{t.visits === 1 ? '' : 's'}{t.last_seen_at ? `, last seen ${when(t.last_seen_at)}` : ''}.</p>
      {t.signals.length > 0 && <p className="small">{t.signals.map((s) => s.label).join(' · ')}</p>}
      {t.chats.length > 0 && <ul className="lt-list">{t.chats.map((c) => <li key={c.id}><Link prefetch={false} className="link" href={`${chatBase}?id=${c.id}`}>Live chat {c.number}</Link> <span className="muted">{when(c.at)}, {c.messages} messages, {c.status}</span></li>)}</ul>}
      <ol className="ad-timeline">{t.events.map((e, i) => (
        <li key={i}><time>{when(e.at)}</time><span><b>{WORDS[e.kind] ?? e.kind}</b>{e.kind === 'page_view' && e.page ? ` ${e.page}` : ''}{e.car ? `: ${e.car}` : ''}{e.booking_number ? ` (${e.booking_number})` : ''}</span></li>))}</ol>
    </div>
  );
}
