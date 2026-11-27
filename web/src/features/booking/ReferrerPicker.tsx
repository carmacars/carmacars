'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { searchReferrers, type ReferrerOption } from '@/server/actions/booking';

// 5132: "Who referred you?" on the request form. Typing 3 letters lists the team members and referral partners whose
// name starts so (a combobox: arrows, Enter, Escape); choosing one credits them on the request. A name typed and not
// chosen is sent as typed, for staff to read; a partner's code typed as is still works.
export function ReferrerPicker({ value, chosen, onChange }: { value: string; chosen: string; onChange: (text: string, key: string) => void }) {
  const id = useId();
  const [opts, setOpts] = useState<ReferrerOption[]>([]);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const seq = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  // typing searches after a short pause; a newer search wins
  const typed = (text: string) => {
    onChange(text, '');
    if (timer.current) clearTimeout(timer.current);
    const n = ++seq.current;
    if (text.trim().length < 3) { setOpts([]); setOpen(false); return; }
    timer.current = setTimeout(() => { void searchReferrers(text).then((r) => { if (n === seq.current) { setOpts(r); setActive(-1); setOpen(r.length > 0); } }); }, 250);
  };
  const pick = (o: ReferrerOption) => { seq.current++; onChange(o.label, o.key); setOpen(false); setOpts([]); };
  return (
    <div className="field rf-pick">
      <label className="label" htmlFor={`${id}-in`}>Who referred you? <span className="opt">optional</span></label>
      <input className="input" id={`${id}-in`} value={value} autoComplete="off" role="combobox" aria-expanded={open} aria-controls={`${id}-list`} aria-autocomplete="list"
        aria-activedescendant={active >= 0 ? `${id}-o${active}` : undefined} aria-describedby={`${id}-hint`} data-testid="rq-referrer"
        onChange={(e) => typed(e.target.value)}
        onKeyDown={(e) => {
          if (!open || !opts.length) return;
          if (e.key === 'ArrowDown') { e.preventDefault(); setActive((a) => (a + 1) % opts.length); }
          else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => (a <= 0 ? opts.length - 1 : a - 1)); }
          else if (e.key === 'Enter' && active >= 0) { e.preventDefault(); pick(opts[active]!); }
          else if (e.key === 'Escape') setOpen(false);
        }}
        onBlur={() => setTimeout(() => setOpen(false), 150)} />
      {open && <ul className="rf-pick__list" id={`${id}-list`} role="listbox" aria-label="People and partners">
        {opts.map((o, i) => <li key={o.key} id={`${id}-o${i}`} role="option" aria-selected={i === active} className={i === active ? 'is-active' : undefined}
          onMouseDown={(e) => { e.preventDefault(); pick(o); }} data-testid={`rq-referrer-${o.kind}`}><b>{o.label}</b> <span className="muted small">{o.note}</span></li>)}
      </ul>}
      <p className="hint" id={`${id}-hint`}>{chosen ? <span data-testid="rq-referrer-chosen">They will be credited for your booking.</span> : 'Type their name and choose them, or type the code from their flyer or card.'}</p>
    </div>
  );
}
