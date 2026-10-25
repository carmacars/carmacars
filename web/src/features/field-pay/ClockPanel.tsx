'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldClock } from '@/server/actions/field';
import { elapsedClock } from './model';

type Job = { id: string; kind: string; booking_number: string | null; vehicle: string | null; completed_at: string | null };
export interface OpenShift { id: string; started_at: string; note: string | null; jobs?: Job[] | null }

const KIND: Record<string, string> = { handover: 'Handover', return_check_in: 'Return check-in', vehicle_move: 'Vehicle move' };
const at = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' });

// My hours (0165): two big buttons. Clock in starts the shift now; Clock out ends it (a note on either). The jobs done during
// the shift are listed while it runs. The database refuses a second shift, a shift left open for too long, and a closed pay period.
export function ClockPanel({ open }: { open: OpenShift | null }) {
  const router = useRouter();
  const [note, setNote] = useState('');
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { if (!open) return; const t = setInterval(() => setNow(Date.now()), 30_000); return () => clearInterval(t); }, [open]);
  const go = (what: 'in' | 'out') => start(async () => {
    setMsg(null);
    const r = await fieldClock(what, note);
    if (!r.ok) { setMsg(r.message); return; }
    setNote('');
    router.refresh();
  });
  return (
    <section className="fd-card" aria-labelledby="clk-t" data-testid="clock-panel">
      <h2 className="d4" id="clk-t">{open ? 'You are clocked in' : 'Not clocked in'}</h2>
      {open && <>
        <p className="fd-big" data-testid="clock-elapsed" aria-live="polite">{elapsedClock(open.started_at, now)}</p>
        <p className="small muted">Since {at(open.started_at)}{open.note ? `: ${open.note}` : ''}</p>
        {open.jobs && open.jobs.length > 0 && <ul className="fd-shots" data-testid="clock-jobs" aria-label="Jobs done in this shift">{open.jobs.map((j) => (
          <li key={j.id}><span>{KIND[j.kind] ?? j.kind.replace(/_/g, ' ')}{j.booking_number ? ` · ${j.booking_number}` : ''}</span><span>{j.vehicle ?? ''}{j.completed_at ? `, done ${at(j.completed_at)}` : ''}</span></li>))}</ul>}
      </>}
      <label className="label" htmlFor="clk-note">Note (optional)</label>
      <input id="clk-note" className="input" value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} placeholder={open ? 'For example: returned the car to the lot' : 'For example: starting at the lot'} />
      {open
        ? <button type="button" className="btn btn--primary fd-go" data-testid="clock-out" disabled={pending} onClick={() => go('out')}>{pending ? 'Working' : 'Clock out'}</button>
        : <button type="button" className="btn btn--primary fd-go" data-testid="clock-in" disabled={pending} onClick={() => go('in')}>{pending ? 'Working' : 'Clock in'}</button>}
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
    </section>
  );
}
