'use client';
import { useRouter } from 'next/navigation';
import { useMemo, useState } from 'react';
import { bookSlot, cancelBooking } from '@/server/actions/careers';
import { fmtDay, fmtSlot, MANILA, torontoDay } from './model';
import type { BookingView } from '@/server/careers';

// Pick an interview time (migration 0173): the open slots grouped by day, Toronto time (and Manila time for a remote role).
// One tap chooses, Confirm books; a booked call can be moved (pick another, Confirm) or cancelled. The database locks the slot.
export function BookingPicker({ token, v }: { token: string; v: BookingView }) {
  const router = useRouter();
  const [pick, setPick] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: 'ok' | 'error'; text: string } | null>(null);
  const days = useMemo(() => {
    const m = new Map<string, BookingView['slots']>();
    for (const s of v.slots) { const k = torontoDay(s.starts_at); m.set(k, [...(m.get(k) ?? []), s]); }
    return [...m.entries()];
  }, [v.slots]);
  const booked = v.booked;
  const both = (iso: string) => <>{fmtSlot(iso)}{v.remote && <span className="cr-alt"> ({fmtSlot(iso, MANILA)} in Manila)</span>}</>;

  async function confirm() {
    if (!pick) return;
    setBusy(true); setMsg(null);
    const r = await bookSlot(token, pick);
    setBusy(false);
    if (!r.ok) { setMsg({ tone: 'error', text: r.message }); router.refresh(); return; }
    setMsg({ tone: 'ok', text: r.moved ? 'Moved. We emailed you the new time.' : 'Booked. We emailed you the details.' });
    setPick(null);
    router.refresh();
  }
  async function cancel() {
    if (!confirmCancel()) return;
    setBusy(true); setMsg(null);
    const r = await cancelBooking(token);
    setBusy(false);
    setMsg(r.ok ? { tone: 'ok', text: 'Cancelled. You can book another time below.' } : { tone: 'error', text: r.message });
    router.refresh();
  }

  if (!v.can_book && !booked) {
    return (<><h1 className="d2">Hi {v.first_name}</h1>
      <p data-testid="book-closed">{v.status === 'interviewed' || v.status === 'hired' || v.status === 'rejected' ? 'Your interview call has taken place. We will write to you with our decision.' : 'This link cannot book a call. If you think this is a mistake, reply to our email.'}</p></>);
  }
  return (
    <div className="stack-lg" data-testid="booking">
      <h1 className="d2">{booked ? `Your interview call, ${v.first_name}` : `Book your interview call, ${v.first_name}`}</h1>
      <p className="muted">{v.role_title}. About 15 minutes. Times are Toronto time{v.remote ? ', with Manila time beside them' : ''}.</p>
      {msg && <p className={`alert${msg.tone === 'error' ? ' alert--error' : ''}`} role={msg.tone === 'error' ? 'alert' : 'status'} data-testid="book-msg"><span>{msg.text}</span></p>}
      {booked && (
        <div className="cr-booked" data-testid="book-booked">
          <p className="d4">{both(booked.starts_at)}</p>
          <p>{booked.mode === 'video'
            ? (booked.meet_url ? <>Video call: <a className="link" href={booked.meet_url} rel="noopener" target="_blank">{booked.meet_url}</a>. Open it a minute before the time.</> : 'A video call: the link is in your email.')
            : <>We will call you at the number ending {v.phone_last || 'on your application'}.</>}</p>
          <p className="row"><button type="button" className="btn btn--ghost" disabled={busy} onClick={cancel} data-testid="book-cancel">Cancel the call</button></p>
          <p className="small muted">To move it, pick another time below and confirm.</p>
        </div>
      )}
      {days.length === 0
        ? <p className="alert" role="status" data-testid="book-none"><span>No call times are open right now. We&apos;ll email you as soon as new times open.</span></p>
        : <div className="stack-lg">
            {days.map(([day, slots]) => (
              <fieldset key={day} className="cr-day">
                <legend className="d4">{fmtDay(day)}</legend>
                <div className="cr-slots">
                  {slots.map((s) => {
                    const mine = booked?.slot_id === s.id;
                    return (
                      <label key={s.id} className={`cr-slot${pick === s.id ? ' is-picked' : ''}${mine ? ' is-mine' : ''}`}>
                        <input type="radio" name="slot" value={s.id} checked={pick === s.id} disabled={mine} onChange={() => setPick(s.id)} data-testid="book-slot" />
                        <span>{fmtSlot(s.starts_at, undefined, false)}{v.remote && <span className="cr-alt">{fmtSlot(s.starts_at, MANILA, false)} Manila</span>}{mine && <span className="cr-alt">your call</span>}</span>
                      </label>
                    );
                  })}
                </div>
              </fieldset>
            ))}
            <div className="cr-confirm">
              <button type="button" className="btn btn--primary btn--lg" disabled={!pick || busy} onClick={confirm} data-testid="book-confirm">
                {busy ? 'Booking' : pick ? `${booked ? 'Move to' : 'Book'} ${fmtSlot(v.slots.find((s) => s.id === pick)!.starts_at)}` : 'Choose a time'}
              </button>
            </div>
          </div>}
    </div>
  );
}
const confirmCancel = () => (typeof window === 'undefined' ? false : window.confirm('Cancel your interview call? You can book another time from this page.'));
