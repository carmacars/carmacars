'use client';
import { useEffect, useId, useRef, useState, type ChangeEvent, type InputHTMLAttributes, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Calendar } from '@/features/calendar/Calendar';
import { clampDay, joinLocal, normalize, pretty, splitLocal, timeOptions, type DateKind } from '@/lib/date-input';
import { clock, torontoToday } from '@/lib/dates';
import './date-picker.css';

type Attrs = Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'value' | 'defaultValue' | 'min' | 'max' | 'size'>;
/** Drop-in for the native date input: the same props, the same `e.target.value` / `name` / `id` in `onChange`. */
export interface DateInputProps extends Attrs {
  type?: DateKind;
  value?: string;
  defaultValue?: string;
  min?: string;
  max?: string;
}

const ICON = <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5.5h14v11H3zM3 9h14M6.5 3v4M13.5 3v4" fill="none" stroke="currentColor" strokeWidth="1.6" /></svg>;
const FAR_PAST = '1990-01-01', FAR_FUTURE = '2100-12-31';

/** The one date field of the admin, staff and customer portals (Release 27): the public booking calendar in a popover (a bottom
 * sheet on a phone), a text box that still takes a typed 2026-11-07, a 15-minute time list for a date and time. It posts the same
 * `name` and the same value (`YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, `HH:MM`) the native inputs did. */
export function DateInput({ type, value: valueProp, defaultValue, min: minProp, max: maxProp, className, style, onChange, onBlur, placeholder, name, id: idProp, required, disabled, autoFocus, ...rest }: DateInputProps) {
  const p = { type, min: minProp, max: maxProp, className, placeholder, name, required, disabled, autoFocus, onBlur, 'aria-label': rest['aria-label'] };
  const kind = p.type ?? 'date';
  const auto = useId();
  const id = idProp ?? auto;
  const [inner, setInner] = useState(defaultValue ?? '');
  const value = valueProp ?? inner;
  const [text, setText] = useState<string | null>(null); // what is being typed (null: show the words)
  const [open, setOpen] = useState(false);
  const [phone, setPhone] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const field = useRef<HTMLInputElement>(null);
  const opener = useRef<HTMLButtonElement>(null);
  const [today, setToday] = useState('');

  const emit = (v: string) => {
    setInner(v);
    const t = { value: v, name: p.name ?? '', id };
    onChange?.({ target: t, currentTarget: t } as unknown as ChangeEvent<HTMLInputElement>);
  };

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
  function close() { setOpen(false); if (opener.current && document.contains(opener.current)) opener.current.focus(); }

  const min = p.min || FAR_PAST, max = p.max || FAR_FUTURE;
  const { day, time } = splitLocal(value);

  // a time on its own is one list
  if (kind === 'time') {
    return (
      <select id={id} name={p.name} className={p.className ?? 'select'} value={value} required={p.required} disabled={p.disabled} aria-label={rest['aria-label']}
        aria-describedby={rest['aria-describedby']} aria-invalid={rest['aria-invalid']} data-testid={(rest as Record<string, string>)['data-testid']} onChange={(e) => emit(e.target.value)} onBlur={() => onBlur?.(undefined as never)}>
        {!value && <option value="">{p.placeholder ?? 'Time'}</option>}
        {timeOptions(15, value).map((t) => <option key={t} value={t}>{clock(t)}</option>)}
      </select>
    );
  }

  const extra = (className ?? '').split(/\s+/).filter((c) => c && !c.startsWith('input')).join(' ');
  const shown = text ?? pretty(kind, value);
  const typed = (s: string) => {
    setText(s);
    const v = normalize(kind, s);
    const off = v && clampDay(v.slice(0, 10), p.min, p.max) !== v.slice(0, 10);
    field.current?.setCustomValidity(s.trim() && !v ? (kind === 'date' ? 'Use the form 2026-11-07, or pick from the calendar.' : 'Use the form 2026-11-07 14:30, or pick from the calendar.') : off ? 'That date is not available.' : '');
    if (v) emit(v);
    else if (!s.trim()) emit('');
  };
  const pickDay = (d: string) => {
    const v = kind === 'datetime-local' ? joinLocal(d, time) : d;
    setText(null); field.current?.setCustomValidity(''); emit(v);
    if (kind === 'date') close();
  };
  const setTime = (t: string) => emit(joinLocal(day || clampDay(today || torontoToday(), p.min, p.max), t));

  const popover = (
    <div className="popover dp__pop" role="dialog" aria-label="Choose a date" ref={pop} hidden={!open}>
      <Calendar single bare months={1} min={min} max={max} today={today} start={clampDay(today, min, max)} maxDays={36500} from={day} to={day} onChange={(v) => pickDay(v.from)} />
      {kind === 'datetime-local' && (
        <div className="dp__time">
          <label className="label" htmlFor={`${id}-time`}>Time</label>
          <select id={`${id}-time`} className="select" value={time || '09:00'} onChange={(e) => setTime(e.target.value)}>
            {timeOptions(15, time).map((t) => <option key={t} value={t}>{clock(t)}</option>)}
          </select>
        </div>
      )}
      <div className="popover__foot">
        <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setText(null); field.current?.setCustomValidity(''); emit(''); close(); }}>Clear</button>
        <button type="button" className="btn btn--sm" onClick={close}>Done</button>
      </div>
    </div>
  );
  const body: ReactNode = open && phone ? createPortal(<><div className="popover-scrim" onClick={close} /> {popover}</>, document.body) : popover;

  return (
    <div className={`dp${extra ? ` ${extra}` : ''}`} style={style} ref={wrap}>
      <input {...rest} ref={field} id={id} type="text" data-value={value} inputMode="numeric" autoComplete="off" className="input dp__text" value={shown} required={p.required} disabled={p.disabled}
        placeholder={p.placeholder ?? (kind === 'date' ? 'YYYY-MM-DD' : 'YYYY-MM-DD HH:MM')}
        autoFocus={p.autoFocus}
        onFocus={() => { if (value) setText(kind === 'date' ? value : value.replace('T', ' ')); }}
        onChange={(e) => typed(e.target.value)}
        onBlur={(e) => { const v = normalize(kind, text ?? ''); if (v || !(text ?? '').trim()) setText(null); onBlur?.(e); }} />
      {p.name && <input type="hidden" name={p.name} value={value} disabled={p.disabled} />}
      <button type="button" ref={opener} className="dp__btn" aria-label="Open calendar" aria-haspopup="dialog" aria-expanded={open} disabled={p.disabled}
        onClick={() => { setToday(torontoToday()); setOpen((o) => !o); }}>{ICON}</button>
      {body}
    </div>
  );
}

/** An input that is a date field when its type is one, and the plain input for any other type (for forms that pick the type by data). */
export function TypedInput(props: InputHTMLAttributes<HTMLInputElement>) {
  const t = props.type;
  if (t === 'date' || t === 'datetime-local' || t === 'time') {
    const { value, defaultValue, min, max, ...r } = props;
    return <DateInput {...r} type={t as DateKind} value={value === undefined ? undefined : String(value)} defaultValue={defaultValue === undefined ? undefined : String(defaultValue)} min={min === undefined ? undefined : String(min)} max={max === undefined ? undefined : String(max)} />;
  }
  return <input {...props} />;
}
