'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { bookCheckin } from '@/server/actions/checkins';
import { dayWords, slotsByDay, timeWords, type RenterState, type Visit } from './model';
import './checkins.css';

// Pick a time for the monthly check-in visit (release 50, migration 4000): the office slots by day (one tap picks, Book
// it confirms), or "By request" with when and where suits the renter (staff confirm). A booked time can be changed or
// taken back. The database checks the slot is still free.
export function PickTime({ number, s }: { number: string; s: RenterState }) {
  const router = useRouter();
  const a = useAct<{ visit: Visit }>();
  const [mode, setMode] = useState<'office' | 'request'>(s.visit?.place === 'request' ? 'request' : 'office');
  const [pick, setPick] = useState<string | null>(null);
  const [note, setNote] = useState(s.visit?.request_note ?? '');
  const days = slotsByDay(s.slots ?? []);
  const v = s.visit;
  const booked = v?.status === 'booked';
  const send = (p: Parameters<typeof bookCheckin>[1]) => a.run(() => bookCheckin(number, p), (r) => { if (r.ok) { setPick(null); router.refresh(); } });
  return (
    <div className="stack" data-testid="checkin-pick-time">
      {booked && v && (
        <section className="pt-card stack" data-testid="checkin-booked">
          <h2 className="d4">Booked</h2>
          <p>{v.place === 'request' ? `By request: ${v.request_note ?? ''}. We will confirm the time with you.` : `${dayWords(v.slot_at ? new Date(v.slot_at).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }) : v.due_on)}, ${v.slot_at ? timeWords(v.slot_at) : ''}. ${v.place_words}.`}</p>
          <p><button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} onClick={() => send({ cancel: true })} data-testid="checkin-cancel">Take the time back</button></p>
          <p className="small muted">To move it, pick another time below.</p>
        </section>
      )}
      <div className="row ci-modes" role="radiogroup" aria-label="Where">
        <label className="check"><input type="radio" name="ci-mode" checked={mode === 'office'} onChange={() => setMode('office')} data-testid="checkin-mode-office" /> <span>At our office</span></label>
        <label className="check"><input type="radio" name="ci-mode" checked={mode === 'request'} onChange={() => setMode('request')} data-testid="checkin-mode-request" /> <span>By request</span></label>
      </div>
      {mode === 'office' ? (
        days.length === 0 ? <p className="muted" data-testid="checkin-no-slots">No office times are open right now. Choose By request and tell us what suits you.</p> : (
          <div className="stack ci-days" data-testid="checkin-slots">
            {days.map(([d, list]) => (
              <fieldset key={d} className="ci-day"><legend className="label">{dayWords(d)}</legend>
                <div className="ci-slots">{list.map((x) => (
                  <button key={x.at} type="button" className={`btn btn--sm ${pick === x.at ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={pick === x.at} onClick={() => setPick(x.at)} data-testid="checkin-slot">{timeWords(x.at)}</button>))}
                </div>
              </fieldset>))}
            <p><button type="button" className="btn btn--primary" disabled={!pick || a.pending} onClick={() => pick && send({ slot_at: pick, place: 'office' })} data-testid="checkin-book">{a.pending ? 'Booking' : 'Book this time'}</button></p>
          </div>)
      ) : (
        <form className="stack" onSubmit={(e) => { e.preventDefault(); if (!a.pending) send({ place: 'request', note }); }} data-testid="checkin-request">
          <div className="field"><label className="label" htmlFor="ci-note">When and where suits you</label>
            <textarea className="input" id="ci-note" rows={3} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} placeholder="For example: weekday evenings, near Yonge and Eglinton" data-testid="checkin-note" /></div>
          <p><button type="submit" className="btn btn--primary" disabled={a.pending || note.trim().length < 3} data-testid="checkin-request-send">{a.pending ? 'Sending' : 'Send my request'}</button></p>
        </form>
      )}
      {a.res && !a.res.ok && <p className="alert alert--warn" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status" data-testid="checkin-done"><span>Thank you. Our team is told; see you then.</span></p>}
    </div>
  );
}
