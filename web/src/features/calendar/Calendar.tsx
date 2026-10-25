'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import { DAYS, MONTHS, addDays, diffDays, dow, longDate, shortDate } from '@/lib/dates';
import { dayState, partText, type Block } from './availability';

// The calendar of prototype/DESIGN.md (CC.Calendar): one or two months, a range picked with two
// taps, unavailable days hatched and struck, part days half hatched (the 2 hour turnaround next to
// another booking), role="grid" with arrow keys, Page Up and Down, Home and End.
export interface CalendarProps {
  months?: 1 | 2;
  min: string;
  today: string;
  blocks?: Block[];
  from?: string;
  to?: string;
  maxDays: number;
  legend?: boolean;
  onChange?: (v: { from: string; to: string }) => void;
}

const ym = (s: string, n: number) => { let y = +s.slice(0, 4); let m = +s.slice(5, 7) - 1 + n; y += Math.floor(m / 12); m = ((m % 12) + 12) % 12; return `${y}-${String(m + 1).padStart(2, '0')}`; };
let uidSeq = 0;

export function Calendar({ months = 1, min, today, blocks = [], from = '', to = '', maxDays, legend = true, onChange }: CalendarProps) {
  const sel = { from, to };
  const [focus, setFocus] = useState(from || min);
  const [view, setView] = useState((from || min).slice(0, 7));
  const [status, setStatus] = useState<{ msg: string; bad: boolean }>(() => {
    if (!from || !to) return { msg: '', bad: false };
    const n = Math.max(1, diffDays(from, to));
    return { msg: `${shortDate(from)} to ${shortDate(to)}, ${n} ${n === 1 ? 'day' : 'days'}.`, bad: false };
  });
  const [seenFrom, setSeenFrom] = useState(from);
  if (from !== seenFrom) { setSeenFrom(from); if (from) { setFocus(from); setView(from.slice(0, 7)); } }
  const [uid] = useState(() => `cal${++uidSeq}`);
  const root = useRef<HTMLDivElement>(null);
  const wantFocus = useRef(false);


  const state = useMemo(() => (iso: string) => dayState(iso, blocks), [blocks]);
  const isBooked = (iso: string) => !!state(iso)?.full;
  const partOf = (iso: string) => { const d = state(iso); return d && !d.full ? d : null; };
  const crosses = (a: string, z: string) => {
    const x = partOf(a); const y = partOf(z);
    if ((x && x.freeUntil != null) || (y && y.freeFrom != null)) return true;
    for (let d = addDays(a, 1); d < z; d = addDays(d, 1)) if (state(d)) return true;
    return false;
  };

  // keep the focused day inside the months shown
  let shownView = view;
  if (focus < `${shownView}-01`) shownView = focus.slice(0, 7);
  const last = ym(shownView, months - 1);
  if (focus.slice(0, 7) > last) shownView = ym(focus.slice(0, 7), -(months - 1));

  useEffect(() => {
    if (!wantFocus.current) return;
    wantFocus.current = false;
    root.current?.querySelector<HTMLButtonElement>(`[data-date="${focus}"]`)?.focus();
  });

  const say = (msg: string, bad = false) => setStatus({ msg, bad });
  function pick(iso: string) {
    if (iso < min) return say('That date has passed.', true);
    if (isBooked(iso)) return say(`${shortDate(iso)} is not available for this car.`, true);
    let next = sel;
    if (!sel.from || sel.to || iso < sel.from) {
      next = { from: iso, to: '' };
      const pp = partOf(iso);
      say(`Pickup ${shortDate(iso)}${pp ? ', ' + partText(pp) : ''}. Now pick a return date.`);
    } else {
      if (crosses(sel.from, iso)) return say('Those dates cross another booking. Pick an earlier return date, or start after it.', true);
      if (diffDays(sel.from, iso) > maxDays) return say(`One booking covers up to ${maxDays} days.`, true);
      next = { from: sel.from, to: iso };
      const n = Math.max(1, diffDays(sel.from, iso)); const zp = partOf(iso);
      say(`${shortDate(sel.from)} to ${shortDate(iso)}, ${n} ${n === 1 ? 'day' : 'days'}.${zp ? ` On ${shortDate(iso)} the car is ${partText(zp)}.` : ''}`);
    }
    setSeenFrom(next.from); setFocus(iso); setView(iso.slice(0, 7)); wantFocus.current = true;
    onChange?.(next);
  }

  function onKey(e: React.KeyboardEvent<HTMLDivElement>) {
    const day = (e.target as HTMLElement).closest<HTMLElement>('[data-date]');
    if (!day) return;
    const d = day.dataset.date!;
    const steps: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7, PageDown: 28, PageUp: -28 };
    let next: string | undefined;
    if (e.key in steps) next = addDays(d, steps[e.key]!);
    else if (e.key === 'Home') next = addDays(d, -dow(d));
    else if (e.key === 'End') next = addDays(d, 6 - dow(d));
    if (next) { e.preventDefault(); if (next < min) next = min; setFocus(next); setView(next.slice(0, 7)); wantFocus.current = true; }
  }

  const monthsList = Array.from({ length: months }, (_, i) => ym(shownView, i));
  const a = +shownView.slice(5, 7) - 1;
  const title = months === 1 ? `${MONTHS[a]} ${shownView.slice(0, 4)}` : `${MONTHS[a]} and ${MONTHS[(a + 1) % 12]}`;
  const focusInView = monthsList.includes(focus.slice(0, 7));

  return (
    <div className={`cal${months === 2 ? ' cal--two' : ''}`} ref={root} onKeyDown={onKey}>
      <div className="cal__head">
        <button type="button" className="icon-btn" aria-label="Previous month" disabled={shownView <= min.slice(0, 7)}
          onClick={() => { const v = ym(shownView, -1); setView(v); setFocus(`${v}-01` < min ? min : `${v}-01`); }}>
          <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg>
        </button>
        <div className="cal__title" id={uid} aria-live="polite">{title}</div>
        <button type="button" className="icon-btn" aria-label="Next month"
          onClick={() => { const v = ym(shownView, 1); setView(v); setFocus(`${v}-01`); }}>
          <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg>
        </button>
      </div>
      <div className="cal__months">
        {monthsList.map((m, mi) => {
          const y = +m.slice(0, 4); const mo = +m.slice(5, 7) - 1;
          const first = new Date(Date.UTC(y, mo, 1)).getUTCDay(); const n = new Date(Date.UTC(y, mo + 1, 0)).getUTCDate();
          const cells: (string | null)[] = [...Array(first).fill(null), ...Array.from({ length: n }, (_, i) => `${m}-${String(i + 1).padStart(2, '0')}`)];
          while (cells.length % 7) cells.push(null);
          const rows = Array.from({ length: cells.length / 7 }, (_, r) => cells.slice(r * 7, r * 7 + 7));
          const firstFree = cells.find((c) => c && c >= min);
          return (
            <div key={m}>
              <div className="cal__month-name">{MONTHS[mo]} {y}</div>
              <table role="grid" aria-labelledby={uid}>
                <thead><tr>{['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'].map((d, i) => <th key={d} scope="col" abbr={DAYS[i]}>{d}</th>)}</tr></thead>
                <tbody>{rows.map((row, ri) => (
                  <tr key={ri}>{row.map((iso, ci) => {
                    if (!iso) return <td key={ci}></td>;
                    const cls = ['cal__day']; let dis = false; let label = longDate(iso);
                    const part = partOf(iso);
                    if (iso < min) { cls.push('is-past'); dis = true; label += ', in the past'; }
                    else if (isBooked(iso)) { cls.push('is-booked'); dis = true; label += ', not available'; }
                    else if (part) { cls.push('is-part'); label += ', partly available, ' + partText(part); }
                    if (iso === today) cls.push('is-today');
                    const isStart = !!sel.from && iso === sel.from; const isEnd = !!sel.to && iso === sel.to;
                    if (isStart) { cls.push('is-start'); label += ', pickup date'; }
                    if (isEnd) { cls.push('is-end'); label += ', return date'; }
                    if (sel.from && sel.to && iso > sel.from && iso < sel.to) cls.push('is-in');
                    const tab = focusInView ? iso === focus : mi === 0 && iso === firstFree;
                    return (
                      <td key={ci}>
                        <button type="button" className={cls.join(' ')} data-date={iso} tabIndex={tab ? 0 : -1} aria-label={label}
                          aria-disabled={dis || undefined} aria-pressed={isStart || isEnd || undefined} onClick={() => pick(iso)}>
                          {+iso.slice(8)}
                        </button>
                      </td>
                    );
                  })}</tr>
                ))}</tbody>
              </table>
            </div>
          );
        })}
      </div>
      <p className={`cal__status${status.bad ? ' red strong' : ''}`} role="status" aria-live="polite">{status.msg}</p>
      {legend && (
        <div className="cal__legend" aria-hidden="true">
          <span><i className="k-sel"></i>Your dates</span><span><i className="k-booked"></i>Not available</span>
          <span><i className="k-part"></i>Part of the day</span><span><i className="k-open"></i>Available</span>
        </div>
      )}
    </div>
  );
}
