'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { prepDo } from '@/server/actions/field-work';
import { DateInput } from '@/components/DateInput';
import { money } from '@/lib/format';
import { PREP_ITEMS, clockText } from './model';

// Fleet and Admin (r35 part X, 0930): each field person's list of the day with its completion and what they left open at clock out,
// and the onboarding prep of cars joining the fleet: give it to a person for a day they hold a shift, and see each car's progress.
export interface WorkLists { day: string; people: Array<{ id: string; name: string; shift: { starts_at: string; ends_at: string } | null; clocked_in: boolean; must: number; done: number;
  cards: Array<{ key: string; type: string; leg: string | null; at: string | null; vehicle: string; booking: string | null; done: boolean }>; left_open: Array<{ label: string; reason: string; at: string }> }> }
export interface PrepList { tasks: Array<{ id: string; vehicle_id: string; vehicle_name: string; staff_id: string; staff_name: string; day: string; status: string; note: string | null;
  items: Array<{ code: string; label: string; done: boolean }>; done_count: number; total: number; spent_cents: number }>;
  cars: Array<{ id: string; name: string }> | null; people: Array<{ id: string; name: string; admin: boolean }>; tracker: boolean }

const WORDS: Record<string, string> = { pickup: 'Pickup', return: 'Return', prep: 'Prep' };

export function WorkListsPanel({ w }: { w: WorkLists }) {
  return (
    <section className="ad-card stack" aria-labelledby="fwl-h" data-testid="field-work-lists">
      <h2 className="d4" id="fwl-h">Field work today: each person&apos;s list</h2>
      {w.people.length === 0 ? <p className="small muted">Nobody holds a shift or has work today.</p> : <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>{w.people.map((p) => (
        <li key={p.id} className="stack" style={{ borderTop: '1px solid var(--line)', paddingTop: 'var(--s-2)' }}>
          <p><b>{p.name}</b> · {p.shift ? `${clockText(p.shift.starts_at)} to ${clockText(p.shift.ends_at)}` : 'no shift'}{p.clocked_in ? ' · clocked in' : ''} · <b>{p.done} of {p.must} done</b></p>
          {p.cards.length > 0 && <p className="small">{p.cards.map((c) => `${c.done ? 'Done' : 'Open'}: ${WORDS[c.leg ?? c.type] ?? c.type} ${c.at ? clockText(c.at) : ''} ${c.vehicle}${c.booking ? ` ${c.booking}` : ''}`).join(' · ')}</p>}
          {p.left_open.length > 0 && <p className="small" style={{ color: 'var(--danger, #9b0c16)' }}>Left open at clock out: {p.left_open.map((o) => `${o.label} (${o.reason})`).join('; ')}</p>}
        </li>))}</ul>}
    </section>
  );
}

export function PrepPanel({ p, vehicle, title = 'Onboarding prep' }: { p: PrepList; vehicle?: { id: string; name: string }; title?: string }) {
  const router = useRouter();
  const [car, setCar] = useState(vehicle?.id ?? p.cars?.[0]?.id ?? '');
  const [staff, setStaff] = useState(p.people[0]?.id ?? '');
  const [day, setDay] = useState(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date()));
  const [items, setItems] = useState<string[]>(['safety_certificate', 'cleaning', 'listing_photos']);
  const [note, setNote] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const choices = PREP_ITEMS.filter(([c]) => c !== 'tracker' || p.tracker);
  const give = () => start(async () => {
    setMsg(null);
    const r = await prepDo('field_prep_assign', { vehicle: car, staff, day, items, note });
    setMsg(r.ok ? { ok: true, text: 'Given. It is on their Today on that day.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return (
    <section className="ad-card stack" aria-labelledby={`prep-h-${vehicle?.id ?? 'all'}`} data-testid="prep-panel">
      <h2 className="d4" id={`prep-h-${vehicle?.id ?? 'all'}`}>{title}</h2>
      {p.tasks.length > 0 && <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>{p.tasks.map((t) => (
        <li key={t.id} className="small"><b>{t.vehicle_name}</b>: {t.staff_name}, {t.day}, {t.status === 'done' ? 'done' : `${t.done_count} of ${t.total} done`}{t.spent_cents ? `, ${money(t.spent_cents, { cents: true })} spent` : ''}
          <br />{t.items.map((i) => `${i.done ? 'Done' : 'To do'}: ${i.label}`).join(' · ')}
          {t.status === 'planned' && <> <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => start(async () => { const r = await prepDo('field_prep_cancel', { id: t.id }); if (r.ok) router.refresh(); else setMsg({ ok: false, text: r.message }); })}>Take it off</button></>}</li>))}</ul>}
      <details><summary className="btn btn--ghost btn--sm">Give onboarding prep to a field person</summary>
        <div className="stack" style={{ marginTop: 'var(--s-2)' }}>
          {!vehicle && <div className="field"><label className="label" htmlFor="prep-car">Car</label><select id="prep-car" className="select" value={car} onChange={(e) => setCar(e.target.value)}>
            {(p.cars ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></div>}
          <div className="field"><label className="label" htmlFor={`prep-who-${vehicle?.id ?? 'all'}`}>Who</label><select id={`prep-who-${vehicle?.id ?? 'all'}`} className="select" value={staff} onChange={(e) => setStaff(e.target.value)}>
            {p.people.map((x) => <option key={x.id} value={x.id}>{x.name}{x.admin ? ' (Admin)' : ''}</option>)}</select></div>
          <div className="field"><label className="label" htmlFor={`prep-day-${vehicle?.id ?? 'all'}`}>Day (one they hold a shift)</label><DateInput id={`prep-day-${vehicle?.id ?? 'all'}`} type="date" className="input" value={day} onChange={(e) => setDay(e.target.value)} /></div>
          <fieldset><legend className="label">What to do</legend>{choices.map(([c, l]) => <label key={c} className="row small"><input type="checkbox" checked={items.includes(c)} onChange={(e) => setItems(e.target.checked ? [...items, c] : items.filter((x) => x !== c))} /> {l}</label>)}</fieldset>
          <div className="field"><label className="label" htmlFor={`prep-note-${vehicle?.id ?? 'all'}`}>Note (optional)</label><input id={`prep-note-${vehicle?.id ?? 'all'}`} className="input" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} /></div>
          <p><button type="button" className="btn btn--primary btn--sm" disabled={pending || !car || !staff || !items.length} onClick={give} data-testid="prep-give">{pending ? 'Giving' : 'Give the prep'}</button></p>
        </div></details>
      {msg && <p className={msg.ok ? 'small' : 'error'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
    </section>
  );
}
