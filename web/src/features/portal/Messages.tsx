'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { sendBookingMessage } from '@/server/actions/portal';
import { when } from '@/features/agreement/model';
import { useAct } from './useAct';

// The booking's messages (migration 0033): what our team wrote (also emailed) and the renter's replies,
// which reach customer service as a task.
export interface Msg { id: string; direction: 'inbound' | 'outbound'; subject: string | null; body: string; at: string; from: string }

export function Messages({ number, thread, prefill }: { number: string; thread: Msg[]; prefill?: string }) {
  const router = useRouter();
  const a = useAct();
  // an action tile (Add a driver, Report a problem) opens the box with the start of the message (?ask=)
  const [text, setText] = useState(prefill ?? '');
  return (
    <section className="pt-card pu-panel" id="messages" aria-labelledby="pt-msgs" data-testid="booking-messages">
      <h2 className="pu-title" id="pt-msgs">Messages</h2>
      {thread.length ? <ol className="pt-thread">{thread.map((m) => (
        <li key={m.id} className={`pt-msg${m.direction === 'inbound' ? ' pt-msg--me' : ''}`}>
          <p className="xs muted">{m.direction === 'inbound' ? 'You' : m.from === 'CarmaCars' ? 'CarmaCars' : `${m.from}, CarmaCars`} · {when(m.at)}</p>
          <p className="pt-msg__body">{m.body}</p>
        </li>))}</ol> : <p className="small muted">No messages yet. Write to us here about this booking.</p>}
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => sendBookingMessage(number, text), (r) => { if (r.ok) { setText(''); router.refresh(); } }); }}>
        <div className={`field${a.err('body') ? ' has-error' : ''}`}>
          <label className="label" htmlFor="pt-msg-body">Your message</label>
          <textarea className="textarea" id="pt-msg-body" value={text} onChange={(e) => setText(e.target.value)} maxLength={4000} aria-invalid={!!a.err('body') || undefined} aria-describedby="pt-msg-err" />
          <p className="error" role="alert" id="pt-msg-err">{a.err('body') ?? (a.res && !a.res.ok ? a.res.message : '')}</p>
        </div>
        {a.res?.ok && <p role="status" className="small">Sent. Our team will reply here and by email.</p>}
        <button className="btn btn--primary" type="submit" disabled={a.pending || !text.trim()} data-testid="booking-message-send">{a.pending ? 'Sending' : 'Send'}</button>
      </form>
    </section>
  );
}
