'use client';
import { useEffect, useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { AddressInput } from '@/features/forms/AddressInput';
import { FdIcon } from './icons';

type A = Parameters<typeof fieldAct>[0];
type F = { name: string; label: string; numeric?: boolean; options?: Array<[string, string]>; required?: boolean; address?: boolean };
// One step on a job card or a small form (acknowledge, start, vehicle moves, damage found later).
// sheet (2026-10-25): the button opens a panel with the fields and its own confirm button, so a gloved tap on the card
// never ends a move or records damage by itself; the panel says what was saved before it closes.
export function FieldButton({ action, payload, label, testId, primary, fields, sheet }: { action: A; payload: Record<string, unknown>; label: string; testId?: string; primary?: boolean;
  fields?: F[]; sheet?: { confirm: string; title?: string } }) {
  const router = useRouter();
  const uid = useId();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const first = useRef<HTMLDivElement>(null);
  const [vals, setVals] = useState<Record<string, string>>(() => Object.fromEntries((fields ?? []).map((f) => [f.name, f.options?.[0]?.[0] ?? ''])));
  useEffect(() => { if (open) first.current?.querySelector<HTMLElement>('input, select')?.focus(); }, [open]);
  const run = () => start(async () => {
    setErr(null); setOk(null);
    const extra: Record<string, unknown> = {};
    for (const f of fields ?? []) { const v = vals[f.name]?.trim() ?? ''; if (f.required && !v) { setErr(`${f.label} is required.`); return; } if (v) extra[f.name] = f.numeric ? Number(v) : v; }
    const nested = action === 'late_damage' ? { damage: extra } : extra;
    let r: Awaited<ReturnType<typeof fieldAct>>;
    try { r = await fieldAct(action, { ...payload, ...nested }); } catch { setErr('No connection. Nothing was saved: try again when you have signal.'); return; }
    if (!r.ok) { setErr(r.message); return; }
    setOpen(false);
    if (fields?.length) setOk('Saved.');
    router.refresh();
  });
  const inputs = fields?.map((f) => (
    <label key={f.name} className="field"><span className="label">{f.label}</span>
      {f.address ? <AddressInput id={`fb-${f.name}`} name={f.name} value={{ label: vals[f.name] ?? '', placeId: '' }} onChange={(x) => setVals((s) => ({ ...s, [f.name]: x.label }))} />
        : f.options ? <select className="select" value={vals[f.name]} onChange={(e) => setVals({ ...vals, [f.name]: e.target.value })}>{f.options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        : <input className={`input${f.numeric ? ' fd-num fd-num--sm' : ''}`} inputMode={f.numeric ? 'numeric' : undefined} value={vals[f.name] ?? ''} onChange={(e) => setVals({ ...vals, [f.name]: f.numeric ? e.target.value.replace(/[^\d]/g, '') : e.target.value })} />}
    </label>));
  const status = <>
    {err && <p className="error" role="alert">{err}</p>}
    <p className="fd-saved" role="status" hidden={!ok}>{ok ? <><FdIcon name="check" />{ok}</> : null}</p>
  </>;
  if (sheet) return (
    <div className="fd-act">
      <button className={`btn ${primary && !open ? 'btn--primary' : 'btn--ghost'} fd-wide`} type="button" aria-expanded={open} aria-controls={`${uid}-sheet`} onClick={() => { setErr(null); setOk(null); setOpen(!open); }} data-testid={testId}>{label}</button>
      {open && <div className="fd-sheet" id={`${uid}-sheet`} role="group" aria-labelledby={`${uid}-t`} ref={first}>
        <p className="fd-sheet__h" id={`${uid}-t`}>{sheet.title ?? label}</p>
        {inputs}
        <div className="fd-sheet__do">
          <button className="btn btn--primary fd-wide" type="button" disabled={pending} onClick={run} data-testid={testId ? `${testId}-confirm` : undefined}>{pending ? 'Saving' : sheet.confirm}</button>
          <button className="btn btn--ghost fd-wide" type="button" disabled={pending} onClick={() => setOpen(false)}>Cancel</button>
        </div>
      </div>}
      {status}
    </div>
  );
  return (
    <div className="fd-act">
      {inputs}
      <button className={`btn ${primary ? 'btn--primary' : 'btn--ghost'} fd-wide`} type="button" disabled={pending} onClick={run} data-testid={testId}>{pending ? 'Working' : label}</button>
      {status}
    </div>
  );
}
