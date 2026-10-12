'use client';
import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { shortDate } from '@/lib/dates';
import { Calendar } from './Calendar';
import type { Block } from './availability';

// Date range field (prototype [data-daterange]): two buttons open one popover calendar, a bottom
// sheet on phones, lifted to <body> so no parent stacking context can trap it.
export function DateRange({ id, from, to, min, today, maxDays, blocks, onChange }: {
  id: string; from: string; to: string; min: string; today: string; maxDays: number; blocks?: Block[]; onChange: (v: { from: string; to: string }) => void;
}) {
  const [open, setOpen] = useState(false);
  const [phone, setPhone] = useState(false);
  const [two, setTwo] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const opener = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    const mq = window.matchMedia('(max-width: 43.99rem)');
    const set = () => { setPhone(mq.matches); setTwo(!mq.matches); };
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

  function close() { setOpen(false); if (opener.current && document.contains(opener.current)) opener.current.focus(); }
  const toggle = (b: HTMLButtonElement) => { opener.current = b; setOpen((o) => !o); };

  const popover = (
    <div className="popover" role="dialog" aria-label="Choose pickup and return dates" ref={pop} hidden={!open}>
      <Calendar months={two ? 2 : 1} min={min} today={today} maxDays={maxDays} blocks={blocks} from={from} to={to} onChange={onChange} />
      <div className="popover__foot">
        <button type="button" className="btn btn--quiet btn--sm" onClick={() => onChange({ from: '', to: '' })}>Clear dates</button>
        <button type="button" className="btn btn--sm" onClick={close}>Done</button>
      </div>
    </div>
  );

  return (
    <div className="daterange" ref={wrap}>
      <div className="daterange__btns">
        {(['from', 'to'] as const).map((k, i) => {
          const v = k === 'from' ? from : to;
          return (
            <div key={k}>
              <span className="label" id={`${id}-l${i + 1}`}>{k === 'from' ? 'Pickup date' : 'Return date'}</span>
              <button type="button" className={`datefield${v ? '' : ' is-empty'}`} aria-labelledby={`${id}-l${i + 1} ${id}-v${i + 1}`}
                aria-haspopup="dialog" aria-expanded={open} onClick={(e) => toggle(e.currentTarget)}>
                <span id={`${id}-v${i + 1}`}>{v ? shortDate(v) : 'Add date'}</span>
                <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5.5h14v11H3zM3 9h14M6.5 3v4M13.5 3v4" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg>
              </button>
            </div>
          );
        })}
      </div>
      {open && phone ? createPortal(<><div className="popover-scrim" onClick={close} />{popover}</>, document.body) : popover}
    </div>
  );
}
