'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';
import type { WeekBlocks } from './RemoteDuties';

// A remote Sales rep's availability blocks for this week or next (migration 0174, va_do sales_availability_save), Toronto
// time. Days already past keep their blocks; the database checks the week, the times and overlaps.
type Row = { day: string; from: string; to: string };
const DAY = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', weekday: 'long', month: 'short', day: 'numeric' }).format(new Date(`${iso}T12:00:00Z`));
const addDays = (iso: string, n: number) => { const d = new Date(`${iso}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

export function AvailabilityForm({ week, next, today }: { week: WeekBlocks; next: WeekBlocks; today: string }) {
  const router = useRouter();
  const id = useId();
  const [which, setWhich] = useState<'this' | 'next'>('this');
  const w = which === 'this' ? week : next;
  const days = Array.from({ length: 7 }, (_, i) => addDays(w.start, i)).filter((x) => x >= today);
  const fromWeek = (x: WeekBlocks): Row[] => x.blocks.filter((b) => b.day >= today).map((b) => ({ day: b.day, from: b.from, to: b.to === '24:00' ? '23:59' : b.to }));
  const [rows, setRows] = useState<Row[]>(fromWeek(week));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();

  const pick = (k: 'this' | 'next') => { setWhich(k); setRows(fromWeek(k === 'this' ? week : next)); setMsg(null); };
  const set = (i: number, patch: Partial<Row>) => setRows((r) => r.map((x, j) => (j === i ? { ...x, ...patch } : x)));
  const save = () => start(async () => {
    const res = await vaAct<{ peak_hours: number }>('sales_availability_save', { week: w.start, blocks: rows.map((r) => ({ day: r.day, from: r.from, to: r.to === '23:59' ? '24:00' : r.to })) }, ['/staff']);
    if (res.ok) { setMsg({ ok: true, text: `Saved: ${res.data.peak_hours} peak hours that week.` }); router.refresh(); } else setMsg({ ok: false, text: res.message });
  });

  return (
    <div className="stack" data-testid="availability">
      <h3 className="va-duty-h" id={`${id}-h`}>My availability</h3>
      <div className="ad-filters" role="group" aria-labelledby={`${id}-h`}>
        <button type="button" className={`btn btn--sm ${which === 'this' ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={which === 'this'} onClick={() => pick('this')}>{week.label}</button>
        <button type="button" className={`btn btn--sm ${which === 'next' ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={which === 'next'} onClick={() => pick('next')} data-testid="availability-next">{next.label}</button>
      </div>
      <p className="small muted">{w.peak_hours} peak hours scheduled ({w.hours} hours in all). Add the blocks you will be on chats, texts and calls, Toronto time.</p>
      {rows.length === 0 && <p className="small">No blocks yet for this week.</p>}
      <ul className="va-blocks">
        {rows.map((r, i) => (
          <li key={i} className="va-block" data-testid={`availability-row-${i}`}>
            <label className="field"><span className="label">Day</span>
              <select className="input" value={r.day} onChange={(e) => set(i, { day: e.target.value })}>{days.map((x) => <option key={x} value={x}>{DAY(x)}</option>)}</select></label>
            <label className="field"><span className="label">From</span><input className="input" type="time" step={900} value={r.from} onChange={(e) => set(i, { from: e.target.value })} /></label>
            <label className="field"><span className="label">To</span><input className="input" type="time" step={900} value={r.to} onChange={(e) => set(i, { to: e.target.value })} /></label>
            <button type="button" className="btn btn--ghost btn--sm" onClick={() => setRows((x) => x.filter((_, j) => j !== i))} aria-label={`Remove the block on ${DAY(r.day)}`}>Remove</button>
          </li>))}
      </ul>
      <div className="ad-actions">
        <button type="button" className="btn btn--ghost btn--sm" disabled={days.length === 0} data-testid="availability-add"
          onClick={() => setRows((x) => [...x, { day: days.find((d) => [4, 5, 6, 0].includes(new Date(`${d}T12:00:00Z`).getUTCDay())) ?? days[0]!, from: '12:00', to: '18:00' }])}>Add a block</button>
        <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={save} data-testid="availability-save">{pending ? 'Saving' : 'Save the week'}</button>
      </div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--warn'}`} role="status">{msg.text}</p>}
    </div>
  );
}
