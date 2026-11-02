'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Calendar } from '@/features/calendar/Calendar';
import { shortDate, torontoToday } from '@/lib/dates';
import { QUICK_RANGES, activeRange, rangeFor } from '@/lib/nav/range';
import './date-picker.css';
import './quick-range.css';

const ICON = <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5.5h14v11H3zM3 9h14M6.5 3v4M13.5 3v4" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg>;

/** One date range field (Release 27): the public booking calendar with two months in a popover (a bottom sheet on a phone), the quick
 * ranges (Today, 7 days, 30 days, 90 days) above it, two hidden inputs that post the same `from` and `to` the two native date
 * inputs did. Inside a form it sends the form as soon as a range is chosen (`autoSubmit`, on by default). */
export function DateRangePicker({ id, label, fromName = 'from', toName = 'to', from: f0 = '', to: t0 = '', min, max, quick = true, autoSubmit = true, onChange }: {
  id?: string; label: string; fromName?: string; toName?: string; from?: string; to?: string; min?: string; max?: string; quick?: boolean; autoSubmit?: boolean;
  onChange?: (v: { from: string; to: string }) => void;
}) {
  const auto = useId();
  const bid = id ?? auto;
  const [v, setV] = useState({ from: f0, to: t0 });
  const [seen, setSeen] = useState(`${f0}|${t0}`);
  if (seen !== `${f0}|${t0}`) { setSeen(`${f0}|${t0}`); setV({ from: f0, to: t0 }); }
  const [open, setOpen] = useState(false);
  const [phone, setPhone] = useState(false);
  const [today, setToday] = useState('');
  const wrap = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const opener = useRef<HTMLButtonElement>(null);
  const submit = useRef(false);

  useEffect(() => {
    const mq = window.matchMedia('(max-width: 43.99rem)');
    const set = () => setPhone(mq.matches);
    set(); mq.addEventListener('change', set); return () => mq.removeEventListener('change', set);
  }, []);
  useEffect(() => {
    if (!open) return;
    const outside = (e: MouseEvent) => { const t = e.target as Node; if (!wrap.current?.contains(t) && !pop.current?.contains(t)) close(); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
    document.addEventListener('mousedown', outside); document.addEventListener('keydown', esc);
    if (phone) document.body.style.overflow = 'hidden';
    else if (pop.current && wrap.current) {
      pop.current.style.left = '0px';
      const r = wrap.current.getBoundingClientRect();
      pop.current.style.left = Math.min(0, window.innerWidth - r.left - pop.current.offsetWidth - 16) + 'px';
    }
    requestAnimationFrame(() => pop.current?.querySelector<HTMLButtonElement>('.cal__day[tabindex="0"]')?.focus());
    return () => { document.removeEventListener('mousedown', outside); document.removeEventListener('keydown', esc); document.body.style.overflow = ''; };
  }, [open, phone]);
  // send the form once the hidden inputs hold the new range
  useEffect(() => {
    if (!submit.current) return;
    submit.current = false;
    wrap.current?.closest('form')?.requestSubmit();
  }, [v]);

  function close() { setOpen(false); if (opener.current && document.contains(opener.current)) opener.current.focus(); }
  const set = (n: { from: string; to: string }, done: boolean) => {
    setV(n); onChange?.(n);
    if (done && n.from && n.to) { if (autoSubmit) submit.current = true; setOpen(false); }
  };
  const on = v.from && v.to && today ? activeRange(v.from, v.to, today) : '';
  const lo = min || '1990-01-01', hi = max || '2100-12-31';

  const popover = (
    <div className="popover dp__pop" role="dialog" aria-label={`Choose ${label.toLowerCase()}`} ref={pop} hidden={!open}>
      {quick && (
        <div className="qr dpr__chips" role="group" aria-label="Quick ranges">
          {QUICK_RANGES.map((r) => (
            <button key={r.key} type="button" className={`qr__b${on === r.key ? ' is-on' : ''}`} data-testid={`dpr-${r.key}`}
              onClick={() => set(rangeFor(r.days, today || torontoToday()), true)}>{r.label}</button>
          ))}
        </div>
      )}
      <Calendar months={phone ? 1 : 2} min={lo} max={hi} today={today} start={v.from || today} maxDays={36500} legend={false} from={v.from} to={v.to} onChange={(n) => set(n, true)} />
      <div className="popover__foot">
        <button type="button" className="btn btn--quiet btn--sm" onClick={() => { set({ from: '', to: '' }, false); if (autoSubmit) { submit.current = true; } close(); }}>Clear</button>
        <button type="button" className="btn btn--sm" onClick={close}>Done</button>
      </div>
    </div>
  );
  const words = v.from && v.to ? `${shortDate(v.from)} to ${shortDate(v.to)}` : v.from ? `${shortDate(v.from)} to ...` : 'Any dates';

  return (
    <div className="dpr dp--range" ref={wrap}>
      <span className="label" id={`${bid}-l`}>{label}</span>
      <button type="button" id={bid} ref={opener} className={`datefield dpr__btn${v.from ? '' : ' is-empty'}`} aria-labelledby={`${bid}-l ${bid}-v`} aria-haspopup="dialog" aria-expanded={open}
        onClick={() => { setToday(torontoToday()); setOpen((o) => !o); }}>
        <span id={`${bid}-v`}>{words}</span>{ICON}
      </button>
      <input type="hidden" name={fromName} value={v.from} />
      <input type="hidden" name={toName} value={v.to} />
      {open && phone ? createPortal(<><div className="popover-scrim" onClick={close} />{popover}</>, document.body) : popover}
    </div>
  );
}
