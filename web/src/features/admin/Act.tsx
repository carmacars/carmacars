'use client';
import { useEffect, useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminSaveRow } from '@/server/actions/admin-portal';
import { opsAct } from '@/server/actions/ops';
import { useDoor } from './door';

// The admin portal's action controls. One button or one form per database action: fields are typed
// (money in dollars becomes cents, a percentage becomes basis points, a local date and time becomes an
// instant), the database decides, and its refusal is shown as written. Keyboard: Enter submits, Esc
// closes a dialog.
export type FieldType = 'text' | 'textarea' | 'money' | 'number' | 'percent' | 'date' | 'datetime' | 'select' | 'bool' | 'json' | 'email' | 'tel' | 'list';
export interface Field { name: string; label: string; type?: FieldType; options?: Array<[string, string]>; required?: boolean; hint?: string; value?: unknown; placeholder?: string; wide?: boolean }
type Result = { ok: true; data: unknown } | { ok: false; message: string; fieldErrors?: Record<string, string> };

const pad = (n: number) => String(n).padStart(2, '0');
export function toLocalInput(iso: unknown): string {
  if (typeof iso !== 'string' || !iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function initial(f: Field): string | boolean {
  const v = f.value;
  if (f.type === 'bool') return Boolean(v);
  if (v === null || v === undefined) return '';
  if (f.type === 'money') return (Number(v) / 100).toFixed(2);
  if (f.type === 'percent') return String(Number(v) / 100);
  if (f.type === 'datetime') return toLocalInput(v);
  if (f.type === 'date') return String(v).slice(0, 10);
  if (f.type === 'json') return typeof v === 'string' ? v : JSON.stringify(v, null, 2);
  if (f.type === 'list') return Array.isArray(v) ? v.join(', ') : String(v);
  return String(v);
}
export function convert(f: Field, raw: string | boolean): { v?: unknown; err?: string } {
  if (f.type === 'bool') return { v: Boolean(raw) };
  const s = String(raw ?? '').trim();
  if (!s) return f.required ? { err: 'Required.' } : { v: null };
  switch (f.type) {
    case 'money': { const n = Number(s.replace(/[$,\s]/g, '')); return Number.isFinite(n) ? { v: Math.round(n * 100) } : { err: 'Enter an amount.' }; }
    case 'percent': { const n = Number(s.replace('%', '')); return Number.isFinite(n) ? { v: Math.round(n * 100) } : { err: 'Enter a percentage.' }; }
    case 'number': { const n = Number(s); return Number.isFinite(n) ? { v: n } : { err: 'Enter a number.' }; }
    case 'datetime': { const d = new Date(s); return Number.isNaN(d.getTime()) ? { err: 'Enter a date and time.' } : { v: d.toISOString() }; }
    case 'json': try { return { v: JSON.parse(s) }; } catch { return { err: 'Not valid JSON.' }; }
    case 'list': return { v: s.split(',').map((x) => x.trim()).filter(Boolean) };
    default: return { v: s };
  }
}

export function FieldInput({ f, value, set, err, idp }: { f: Field; value: string | boolean; set: (v: string | boolean) => void; err?: string; idp: string }) {
  const id = `${idp}-${f.name}`;
  const desc = [err ? `${id}-err` : '', f.hint ? `${id}-hint` : ''].filter(Boolean).join(' ') || undefined;
  if (f.type === 'bool') {
    return (
      <div className={`field ad-field${f.wide ? ' ad-field--wide' : ''}`}>
        <label className="check" htmlFor={id}><input id={id} type="checkbox" checked={Boolean(value)} onChange={(e) => set(e.target.checked)} aria-describedby={desc} /> <span>{f.label}</span></label>
        {f.hint && <p className="hint" id={`${id}-hint`}>{f.hint}</p>}
      </div>
    );
  }
  const common = { id, value: String(value), 'aria-invalid': err ? true : undefined, 'aria-describedby': desc, required: f.required, placeholder: f.placeholder };
  return (
    <div className={`field ad-field${err ? ' has-error' : ''}${f.wide || f.type === 'textarea' || f.type === 'json' ? ' ad-field--wide' : ''}`}>
      <label className="label" htmlFor={id}>{f.label}{f.type === 'money' ? ' ($)' : f.type === 'percent' ? ' (%)' : ''}</label>
      {f.type === 'select' ? (
        <select className="select" {...common} onChange={(e) => set(e.target.value)}>
          {!f.required && <option value="">None</option>}
          {f.options?.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
      ) : f.type === 'textarea' || f.type === 'json' ? (
        <textarea className={`input ad-textarea${f.type === 'json' ? ' pt-mono' : ''}`} rows={f.type === 'json' ? 6 : 3} {...common} onChange={(e) => set(e.target.value)} />
      ) : (
        <input className="input" {...common} onChange={(e) => set(e.target.value)}
          type={f.type === 'date' ? 'date' : f.type === 'datetime' ? 'datetime-local' : f.type === 'email' ? 'email' : f.type === 'tel' ? 'tel' : 'text'}
          inputMode={f.type === 'money' || f.type === 'percent' ? 'decimal' : f.type === 'number' ? 'numeric' : undefined} />
      )}
      {f.hint && <p className="hint" id={`${id}-hint`}>{f.hint}</p>}
      {err && <p className="error" role="alert" id={`${id}-err`}>{err}</p>}
    </div>
  );
}

function useForm(fields: Field[]) {
  const [vals, setVals] = useState<Record<string, string | boolean>>(() => Object.fromEntries(fields.map((f) => [f.name, initial(f)])));
  const [errs, setErrs] = useState<Record<string, string>>({});
  const collect = (): Record<string, unknown> | null => {
    const out: Record<string, unknown> = {}; const e: Record<string, string> = {};
    for (const f of fields) { const r = convert(f, vals[f.name] ?? ''); if (r.err) e[f.name] = r.err; else out[f.name] = r.v; }
    setErrs(e);
    return Object.keys(e).length ? null : out;
  };
  return { vals, setVals, errs, setErrs, collect };
}

const fill = (tpl: string, data: unknown) => tpl.replace(/\{(\w+)\}/g, (_, k: string) => encodeURIComponent(String((data as Record<string, unknown> | null)?.[k] ?? '')));

/** A button that runs one action, optionally after a dialog with fields or a confirmation. */
export function Act({ action, payload = {}, fields = [], label, confirm, variant = 'ghost', title, go, done = 'Done.', refresh = [], nest, testId, disabled, inline, submitLabel, ops }: {
  action: string; payload?: Record<string, unknown>; fields?: Field[]; label: string; confirm?: string; variant?: 'primary' | 'ghost' | 'quiet' | 'danger';
  title?: string; go?: string; done?: string; refresh?: string[]; nest?: string; testId?: string; disabled?: boolean; inline?: boolean; submitLabel?: string;
  /** The action is one of migration 0032's (the door's ops_do), the same for an Admin and an assistant. */
  ops?: boolean;
}) {
  const door = useDoor();
  const adminAct = ops ? opsAct : door.act;
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [pending, start] = useTransition();
  const [res, setRes] = useState<Result | null>(null);
  const dlg = useRef<HTMLDialogElement>(null);
  const f = useForm(fields);
  const needsDialog = !inline && (fields.length > 0 || !!confirm);
  const run = () => {
    const vals = f.collect();
    if (!vals) return;
    const body = nest ? { ...payload, [nest]: vals } : { ...payload, ...vals };
    start(async () => {
      const r = (await adminAct(action, body, refresh)) as Result;
      setRes(r);
      if (!r.ok && r.fieldErrors) f.setErrs(r.fieldErrors);
      if (r.ok) {
        dlg.current?.close();
        if (go) router.push(fill(go, r.data)); else router.refresh();
      }
    });
  };
  const cls = `btn btn--sm ${variant === 'primary' ? 'btn--primary' : variant === 'danger' ? 'btn--primary ad-btn--danger' : variant === 'quiet' ? 'btn--quiet' : 'btn--ghost'}`;
  const form = (
    <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); run(); }} data-testid={testId ? `${testId}-form` : undefined}>
      {confirm && <p className="small">{confirm}</p>}
      {fields.length > 0 && <div className="ad-fields">{fields.map((x) => <FieldInput key={x.name} f={x} idp={idp} value={f.vals[x.name] ?? ''} set={(v) => f.setVals((s) => ({ ...s, [x.name]: v }))} err={f.errs[x.name]} />)}</div>}
      {res && !res.ok && <p className="alert alert--error" role="alert"><span>{res.message}</span></p>}
      <div className="row">
        <button className={`btn btn--sm ${variant === 'danger' ? 'btn--primary ad-btn--danger' : 'btn--primary'}`} type="submit" disabled={pending || disabled} data-testid={testId ? `${testId}-submit` : undefined}>{pending ? 'Working' : submitLabel ?? label}</button>
        {needsDialog && <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Cancel</button>}
      </div>
    </form>
  );
  if (inline) return <div className="ad-inline">{form}{res?.ok && done ? <p className="small" role="status">{done}</p> : null}</div>;
  return (
    <>
      <button className={cls} type="button" disabled={pending || disabled} data-testid={testId} aria-haspopup={needsDialog ? 'dialog' : undefined}
        onClick={() => { setRes(null); if (needsDialog) dlg.current?.showModal(); else run(); }}>{pending ? 'Working' : label}</button>
      {!needsDialog && res && !res.ok && <span className="ad-err" role="alert">{res.message}</span>}
      {needsDialog && (
        <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${idp}-t`} onClose={() => setRes(null)}>
          <h2 className="d4" id={`${idp}-t`}>{title ?? label}</h2>
          {form}
        </dialog>
      )}
    </>
  );
}

/** A settings row: add or change, through the allow-listed save of migration 0030. */
export function SaveForm({ table, rowKey, fields, label = 'Save', extra, testId, done = 'Saved.', compact }: {
  table: string; rowKey?: string | null; fields: Field[]; label?: string; extra?: Record<string, unknown>; testId?: string; done?: string; compact?: boolean;
}) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [pending, start] = useTransition();
  const [res, setRes] = useState<Result | null>(null);
  const f = useForm(fields);
  const [dirty, setDirty] = useState(false);
  useEffect(() => { if (res?.ok) { const t = setTimeout(() => setRes(null), 4000); return () => clearTimeout(t); } }, [res]);
  return (
    <form className={`ad-form${compact ? ' ad-form--compact' : ''}`} noValidate data-testid={testId} onSubmit={(e) => {
      e.preventDefault();
      const vals = f.collect(); if (!vals) return;
      // only what changed on an existing row; everything on a new one
      const send = rowKey ? Object.fromEntries(Object.entries(vals).filter(([k]) => { const x = fields.find((y) => y.name === k)!; return convert(x, initial(x)).v !== vals[k] && JSON.stringify(convert(x, initial(x)).v) !== JSON.stringify(vals[k]); })) : vals;
      if (rowKey && !Object.keys(send).length) { setRes({ ok: false, message: 'Nothing changed.' }); return; }
      start(async () => { const r = (await adminSaveRow(table, send, rowKey ?? null, extra)) as Result; setRes(r); if (r.ok) { setDirty(false); router.refresh(); } });
    }}>
      <div className="ad-fields">{fields.map((x) => <FieldInput key={x.name} f={x} idp={idp} value={f.vals[x.name] ?? ''} set={(v) => { setDirty(true); f.setVals((s) => ({ ...s, [x.name]: v })); }} err={f.errs[x.name]} />)}</div>
      {res && !res.ok && <p className="alert alert--error" role="alert"><span>{res.message}</span></p>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid={testId ? `${testId}-save` : undefined}>{pending ? 'Saving' : label}</button>
        {res?.ok && <span className="small" role="status">{done}</span>}
        {dirty && !res && <span className="small muted">Unsaved changes</span>}
      </div>
    </form>
  );
}
