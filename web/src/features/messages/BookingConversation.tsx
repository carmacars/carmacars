import { Badge, Card, t } from '@/features/admin/ui';
import { EmailRenter } from './EmailRenter';
import { emailKind, type Conversation, type Recipient } from './email-choices';

// The booking's conversation and the Email the renter form (migration 0187): what staff and the renter wrote on the
// booking (both ways, the adjuster's emails marked), and every email of the booking with its sender and state. The
// form sends through the outbox; both lists refresh after a send.
export function BookingConversation({ c, refresh, initialTo = 'renter' }: { c: Conversation; refresh: string[]; initialTo?: Recipient }) {
  return (
    <div className="ad-cols ad-cols--2" data-testid="booking-conversation">
      <div className="stack">
        <Card title={c.insurer_billed ? 'Email the renter or the adjuster' : 'Email the renter'} testId="email-card">
          <EmailRenter c={c} refresh={refresh} initialTo={initialTo} />
        </Card>
        <Card title="Emails of this booking" testId="booking-emails">
          {c.emails.length ? (
            <ul className="ad-list">{c.emails.map((e) => (
              <li key={e.id}>
                <span><b>{e.subject}</b> <span className="ad-sub">{emailKind(e.code)}{e.to ? ` to ${e.to}` : ''}{e.from ? `, from ${e.from.replace(/\s*<.*$/, '')}` : ''}, {t(e.sent_at ?? e.at)}</span></span>
                <Badge s={e.status}>{e.status === 'delayed' && e.reason ? `Waiting: ${e.reason}` : undefined}</Badge>
              </li>))}</ul>
          ) : <p className="small muted">No emails yet.</p>}
        </Card>
      </div>
      <Card title="Messages" testId="conversation">
        {c.messages.length ? (
          <ol className="ad-timeline" data-testid="messages">{c.messages.map((m) => (
            <li key={m.id}><time>{t(m.at)}</time>
              <span><b>{m.direction === 'inbound' ? m.by : `${m.by}${m.adjuster ? ' to the adjuster' : ''}`}</b>{m.from?.startsWith('Blind Spot') ? <span className="ad-sub">as Blind Spot Car Rental</span> : null}
                {m.subject ? <> <b>{m.subject}</b></> : null} <span className="wrap">{m.body ?? ''}</span></span></li>))}</ol>
        ) : <p className="small muted">No messages on this booking yet.</p>}
      </Card>
    </div>
  );
}
