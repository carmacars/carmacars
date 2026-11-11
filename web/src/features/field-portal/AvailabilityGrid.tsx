'use client';
import '@/styles/shift-picker.css';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { saveAvailability } from '@/server/actions/field-shifts';
import { PARTS, WEEKDAYS, WEEKDAYS_SHORT, cell, dayCells, partCells, toggleCell, toggleMany, availabilityWords, type Availability } from './shift-picker';

// When a field person can usually work (r35 part SP, 1770): a week of mornings, afternoons and evenings, each a big toggle, a
// weekday or a part toggled at once from its label, and a note. On Welcome (a required onboarding step), Profile and My shifts.
export function AvailabilityGrid({ value, testId = 'availability', submit = 'Save my availability', onboarding = false }: { value: Availability | null; testId?: string; submit?: string; onboarding?: boolean }) {
  const router = useRouter();
  const [slots, setSlots] = useState<string[]>(value?.slots ?? []);
  const [note, setNote] = useState(value?.note ?? '');
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const save = () => start(async () => {
    setMsg(null);
    if (!slots.length) { setMsg({ ok: false, text: 'Tick at least one time you can usually work.' }); return; }
    const r = await saveAvailability(slots, note);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: onboarding && r.data.onboarded ? 'Saved. Your portal is open.' : 'Saved. Fleet plans the shifts from it.' });
    router.refresh();
  });
  const on = new Set(slots);
  return (
    <div className="sp-avail" data-testid={testId}>
      <table className="sp-grid">
        <caption className="vh">When you can usually work</caption>
        <thead><tr><td />{PARTS.map((p) => <th key={p.key} scope="col">
          <button type="button" className="sp-grid__head" onClick={() => setSlots(toggleMany(slots, partCells(p.key)))} aria-label={`Every ${p.label.toLowerCase()}`}>{p.label}<small>{p.hours}</small></button></th>)}</tr></thead>
        <tbody>{WEEKDAYS.map((w, i) => (
          <tr key={w}><th scope="row"><button type="button" className="sp-grid__head" onClick={() => setSlots(toggleMany(slots, dayCells(i + 1)))} aria-label={`All of ${w}`}>{WEEKDAYS_SHORT[i]}</button></th>
            {PARTS.map((p) => { const c = cell(i + 1, p.key); return <td key={c}>
              <button type="button" className="sp-cell" aria-pressed={on.has(c)} aria-label={`${w} ${p.label.toLowerCase()}`} data-testid={`avail-${c}`} onClick={() => setSlots(toggleCell(slots, c))}>
                <span aria-hidden="true">{on.has(c) ? '✓' : ''}</span></button></td>; })}</tr>))}</tbody>
      </table>
      <p className="small" aria-live="polite">{availabilityWords(slots)}</p>
      <label className="field"><span className="label">Anything else (optional)</span>
        <input className="input" value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} placeholder="For example: no Sundays before noon, exams in December" data-testid={`${testId}-note`} /></label>
      <button type="button" className="btn btn--primary sp-wide" disabled={pending} onClick={save} data-testid={`${testId}-save`}>{pending ? 'Saving' : submit}</button>
      {msg && <p className={msg.ok ? 'sp-ok' : 'error'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
    </div>
  );
}
