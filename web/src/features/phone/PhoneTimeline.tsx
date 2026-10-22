'use client';
import './phone.css';
import Link from 'next/link';
import { when } from '@/features/agreement/model';
import { CallBody, type PhoneTimelineData } from './client';

// Calls and texts on a record (migration 0085): the booking (History tab), the renter, the owner. Newest first; a call
// shows its summary, voicemail and, when the line recorded it, the transcript; the thread opens in the inbox.
export function PhoneTimeline({ t, inbox }: { t: PhoneTimelineData | null; inbox: string }) {
  if (!t) return <p className="small muted">Not available.</p>;
  if (!t.items.length) return <p className="small muted" data-testid="phone-timeline-empty">No calls or texts with {t.threads.length ? t.threads.map((x) => x.display).join(', ') : 'this person'} yet.</p>;
  return (
    <div className="stack" data-testid="phone-timeline">
      <ol className="ph-tl">{t.items.map((m) => (
        <li key={m.id} className={m.missed ? 'is-missed' : undefined}>
          <p className="small"><b>{m.kind === 'call' ? (m.missed ? 'Missed call' : m.direction === 'in' ? 'Call in' : 'Call out') : m.direction === 'in' ? 'Text in' : 'Text out'}</b>{' '}
            <span className="muted">{when(m.at)} · {m.number}{m.booking_number ? ` · ${m.booking_number}` : ''}{m.by ? ` · ${m.by}` : ''}</span></p>
          {m.kind === 'text' ? <p className="small">{m.body}</p> : <CallBody m={m} />}
        </li>))}</ol>
      {t.threads.length > 0 && <p className="small">{t.threads.map((x) => <Link key={x.id} prefetch={false} className="link" href={`${inbox}?view=phone&id=${x.id}`}>Open {x.display} in Texts and calls</Link>)}</p>}
    </div>
  );
}
