'use client';
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { DateInput } from '@/components/DateInput';
import { opsAct } from '@/server/actions/ops';
import { DEPOSIT_WORDS, depositChoices, moneyLine, pastDue, type EndedRow } from './ended';

// Close ended trips (1063): every trip past its return time that is not closed. Tick rows (or one), mark them returned on
// time, late at a time, or a no-show, choose the deposit decision, and Close. Nothing is released by itself: the decision
// waits below for an Admin to press Release. An expired card hold is marked settled at once (no money moves).
export function EndedTrips({ rows, base, admin, canNoShow }: { rows: EndedRow[]; base: '/admin' | '/staff'; admin: boolean; canNoShow: boolean }) {
  const [sel, setSel] = useState<string[]>([]);
  const [mark, setMark] = useState<'on_time' | 'late' | 'no_show'>('on_time');
  const [at, setAt] = useState('');
  const [dep, setDep] = useState<'' | 'full' | 'balance' | 'late_fee'>('balance');
  const [waive, setWaive] = useState('');
  const [msg, setMsg] = useState('');
  const [pending, start] = useTransition();
  const router = useRouter();
  const open = rows.filter((r) => !r.decision);
  const waiting = rows.filter((r) => r.decision);
  const picked = useMemo(() => open.filter((r) => sel.includes(r.booking_id)), [open, sel]);
  const all = picked.length === open.length && open.length > 0;
  const toggle = (id: string) => setSel((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));
  const close = () => start(async () => {
    setMsg('');
    const r = await opsAct<{ closed: number; failed: Array<{ booking: string; problem: string }> }>('ended_trips_close_many', {
      bookings: picked.map((x) => x.booking_id), mark, deposit: dep || null, return_at: mark === 'late' && at ? new Date(at).toISOString() : null, deposit_waiver_reason: admin && waive ? waive : null }, [`${base}/bookings`]);
    if (!r.ok) { setMsg(r.message ?? 'Not closed.'); return; }
    setMsg(`${r.data.closed} closed.${r.data.failed.length ? ` Not closed: ${r.data.failed.map((f) => `${f.booking} (${f.problem.replace(/^.*?ERROR:\s*/, '')})`).join('; ')}` : ''}`);
    setSel([]);
    router.refresh();
  });
  const release = (id: string, now: boolean) => start(async () => {
    const r = await opsAct('trip_close_release', { booking: id, release_now: now }, [`${base}/bookings`]);
    setMsg(r.ok ? 'Released: the deposit is settled.' : r.message ?? 'Not released.');
    router.refresh();
  });
  return (
    <div className="stack" data-testid="ended-trips">
      <section className="pt-card ad-card stack" aria-label="Close the trips ticked">
        <h2 className="d4">Trips ended and not closed ({open.length})</h2>
        <p className="small muted">A trip never checked out or in is closed at its booked times (or the time it came back). The renter gets no email for a back-dated close. Deposits are never released by themselves: an Admin presses Release below.</p>
        {open.length > 0 && <div className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'end' }}>
          <label className="small">Mark them<select className="input" value={mark} onChange={(e) => setMark(e.target.value as typeof mark)} data-testid="ended-mark">
            <option value="on_time">Returned on time</option><option value="late">Returned late, at</option>{canNoShow && <option value="no_show">No-show (never picked up)</option>}</select></label>
          {mark === 'late' && <label className="small">Came back at<DateInput className="input" type="datetime-local" value={at} onChange={(e) => setAt(e.target.value)} aria-label="Came back at" /></label>}
          {mark !== 'no_show' && <label className="small">Deposit<select className="input" value={dep} onChange={(e) => setDep(e.target.value as typeof dep)} data-testid="ended-deposit">
            {depositChoices().map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>}
          {admin && mark !== 'no_show' && <label className="small">Admin: deposit not taken, waive it because<input className="input" value={waive} onChange={(e) => setWaive(e.target.value)} maxLength={300} data-testid="ended-waive" /></label>}
          <button type="button" className="btn btn--primary" disabled={pending || !picked.length || (mark === 'late' && !at)} onClick={close} data-testid="ended-close">{pending ? 'Closing' : `Close ${picked.length || ''} ticked`}</button>
        </div>}
        {msg && <p className="small" role="status" data-testid="ended-msg">{msg}</p>}
        {open.length === 0 ? <p className="small muted">Every ended trip is closed.</p> : (
          <div className="ad-table-wrap"><table className="ad-table" data-testid="ended-table">
            <thead><tr><th><input type="checkbox" aria-label="Tick every trip" checked={all} onChange={() => setSel(all ? [] : open.map((r) => r.booking_id))} /></th><th>Booking</th><th>Now</th><th>Car</th><th>Renter</th><th>Return due</th><th>Deposit</th></tr></thead>
            <tbody>{open.map((r) => (
              <tr key={r.booking_id}>
                <td><input type="checkbox" aria-label={`Tick ${r.booking_number}`} checked={sel.includes(r.booking_id)} onChange={() => toggle(r.booking_id)} data-testid={`ended-tick-${r.booking_number}`} /></td>
                <td><Link prefetch={false} className="link" href={`${base}/bookings/${encodeURIComponent(r.booking_number)}`}>{r.booking_number}</Link></td>
                <td className="small">{r.status === 'confirmed' ? 'Pickup not recorded' : r.status === 'on_rent' ? 'On rent' : 'Returned, not closed'}</td>
                <td>{r.vehicle}{r.plate ? <span className="muted small"> · {r.plate}</span> : null}</td>
                <td>{r.renter ?? ''}</td>
                <td className="small">{new Date(r.return_at).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })} <span className="ad-late">{pastDue(r.hours_past)} ago</span></td>
                <td className="small">{moneyLine(r.money)}</td>
              </tr>))}</tbody></table></div>)}
      </section>
      <section className="pt-card ad-card stack" aria-label="Deposit decisions waiting">
        <h2 className="d4">Deposit decisions waiting for an Admin ({waiting.length})</h2>
        {waiting.length === 0 ? <p className="small muted">None.</p> : <ul className="mr-list">{waiting.map((r) => (
          <li key={r.booking_id} data-testid={`ended-decision-${r.booking_number}`}>
            <span><b>{r.booking_number}</b>: {DEPOSIT_WORDS[r.decision!.decision]} ({moneyLine(r.money)}), chosen by {r.decision!.by ?? 'staff'}</span>
            {admin ? <span className="ad-actions"><button type="button" className="btn btn--sm btn--primary" disabled={pending} onClick={() => release(r.booking_id, false)} data-testid={`ended-release-${r.booking_number}`}>Release</button>
              <button type="button" className="btn btn--sm btn--ghost" disabled={pending} onClick={() => release(r.booking_id, true)}>Release now (tolls window)</button></span>
              : <span className="small muted">An Admin presses Release.</span>}
          </li>))}</ul>}
      </section>
    </div>
  );
}
